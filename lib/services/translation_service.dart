// lib/services/translation_service.dart
import 'dart:async';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/services/app_config_service.dart';
import 'package:matchme/utils/encrypted_text_guard.dart';

// Import the appropriate service based on platform to avoid DDC conflicts
// This imports the correct platform-specific file and makes its function available
import 'platform/deepl_translation_service.dart'
    if (dart.library.html) 'platform/web_translation_service.dart';

/// Tracks whether the translate-proxy edge function is accessible.
/// After a 403 response, further calls are suppressed for [TranslationProxy.cooldownDuration].
class TranslationProxy {
  TranslationProxy._();

  static final Map<String, bool> _availabilityByScope = {};
  static final Map<String, DateTime?> _cooldownUntilByScope = {};
  static Duration cooldownDuration = const Duration(minutes: 5);
  static final Map<String, Future<dynamic>> _inFlightRequests = {};

  /// Per-(match, target language) queue tails for BATCH requests. A batch
  /// that arrives while another batch for the same match+language is still
  /// in flight waits for it instead of racing it. Combined with the edge
  /// function's server-side skip/claim, the follower becomes a cheap no-op
  /// rather than a second DeepL pass over the same messages. This covers
  /// callers outside the chat screen (locale-change last-message pass,
  /// Recent-Chats preview) which do not share the chat screen's
  /// single-flight coordinator.
  static final Map<String, Future<void>> _batchQueueTails = {};
  static bool _configLoaded = false;

  /// Whether it's worth attempting a call right now.
  static bool get canTry => canTryForScope('default');

  static bool canTryForScope(String scope) {
    final available = _availabilityByScope[scope] ?? true;
    if (available) return true;
    final cooldownUntil = _cooldownUntilByScope[scope];
    return cooldownUntil != null && DateTime.now().isAfter(cooldownUntil);
  }

  /// Load cooldown config from app config service.
  static Future<void> _loadConfig() async {
    if (_configLoaded) return;
    _configLoaded = true;
    try {
      cooldownDuration = await appConfigService.getDuration(
        'ui.translation_fetch_delay_ms',
        defaultValue: const Duration(minutes: 5),
      );
    } catch (e) {
      // keep default
    }
  }

  /// Call translate-proxy and handle 403 by entering a cooldown.
  static Future<dynamic> invoke({
    required Map<String, dynamic> body,
    Map<String, String>? headers,
  }) async {
    await _loadConfig();
    final scope = _scopeForBody(body);
    if (!canTryForScope(scope)) {
      throw FunctionException(
        status: 403,
        details: {'error': 'translate-proxy is unavailable (cooldown active)'},
        reasonPhrase: null,
      );
    }
    final dedupeKey = _dedupeKey(body);
    final existing = _inFlightRequests[dedupeKey];
    if (existing != null) {
      return existing;
    }

    final batchQueueKey = _batchQueueKey(body);

    final future = (() async {
      // Batch requests for the same match+language run strictly one after
      // another, so a late-arriving batch observes the earlier batch's DB
      // writes and the edge function's skip check filters out anything
      // already translated. Single-text requests bypass the queue.
      if (batchQueueKey != null) {
        while (true) {
          final tail = _batchQueueTails[batchQueueKey];
          if (tail == null) break;
          try {
            await tail;
          } catch (_) {}
        }
      }
      final requestBody = <String, dynamic>{'mode': 'direct', ...body};
      final response = await Supabase.instance.client.functions.invoke(
        'translate-proxy',
        body: requestBody,
        headers: headers,
      );
      // Success — reset cooldown for this scope if we were in one.
      if (_cooldownUntilByScope[scope] != null) {
        _cooldownUntilByScope[scope] = null;
        _availabilityByScope[scope] = true;
      }
      return response;
    })();

    _inFlightRequests[dedupeKey] = future;

    // Chain this batch onto the per-(match, language) queue so concurrent
    // batches serialize instead of overlapping.
    if (batchQueueKey != null) {
      // Declared before assignment so the whenComplete closure can capture
      // the variable itself (the callback only ever runs after assignment).
      Future<void>? myTail;
      myTail = future.then<void>((_) {}, onError: (_) {}).whenComplete(() {
        final tail = myTail;
        // Only clear if we are still the tail — a newer batch may have
        // already chained onto us.
        if (tail != null && identical(_batchQueueTails[batchQueueKey], tail)) {
          _batchQueueTails.remove(batchQueueKey);
        }
      });
      _batchQueueTails[batchQueueKey] = myTail;
    }

    try {
      return await future;
    } on FunctionException catch (e) {
      if (e.status == 403) {
        _enterCooldown(scope);
      }
      rethrow;
    } finally {
      _inFlightRequests.remove(dedupeKey);
    }
  }

  /// Queue key for batch requests: (match_id, target language). Null for
  /// single-text and other non-batch requests, which must never wait on a
  /// chat-history batch.
  static String? _batchQueueKey(Map<String, dynamic> body) {
    final matchId = body['match_id']?.toString();
    final target = (body['target_language'] ?? body['target_lang'])?.toString();
    if (matchId == null || matchId.isEmpty) return null;
    if (target == null || target.isEmpty) return null;
    // Only requests that carry message_ids (or retranslate_all) are
    // history batches; a batched-text array without them uses a different
    // server path and should not serialize behind chat history.
    final hasMessageIds =
        body['message_ids'] is List || body['retranslate_all'] == true;
    if (!hasMessageIds) return null;
    return '$matchId|${normalizeLanguageCode(target)}';
  }

  static String _dedupeKey(Map<String, dynamic> body) {
    // Single-text translation (profile bio/occupation, realtime display, ...):
    // must be keyed by the actual text + languages. Previously these fields
    // were ignored, so two concurrent calls (e.g. bio + occupation on the
    // match profile screen) shared one dedupe key and the second caller
    // received the first caller's translation.
    final singleText = body['text']?.toString();
    if (singleText != null) {
      final targetLang =
          body['target_lang']?.toString() ??
          body['target_language']?.toString();
      final sourceLang =
          body['source_lang']?.toString() ??
          body['source_language']?.toString();
      // Gender shapes the output via the edge's DeepL `context`, so it is
      // part of the identity: concurrent same-text calls for different
      // genders must not share an in-flight request.
      return jsonEncode({
        'kind': 'single',
        'text': singleText,
        'target_lang': targetLang,
        'source_lang': sourceLang,
        'speaker_gender': body['speaker_gender']?.toString(),
        'addressee_gender': body['addressee_gender']?.toString(),
        'context': body['context']?.toString(),
      });
    }

    final ids = body['message_ids'];
    final normalizedIds = ids is List
        ? (ids.map((id) => id.toString()).toList()..sort())
        : const <String>[];
    return jsonEncode({
      'kind': 'batch',
      'action': body['action']?.toString(),
      'request_id': body['request_id']?.toString(),
      'match_id': body['match_id']?.toString(),
      'target_language': body['target_language']?.toString(),
      'source_language': body['source_language']?.toString(),
      'exclude_sender_id': body['exclude_sender_id']?.toString(),
      'message_ids': normalizedIds,
      'retranslate_all': body['retranslate_all'] == true,
    });
  }

  static String _scopeForBody(Map<String, dynamic> body) {
    if (body['message_ids'] is List) {
      return 'chat_batch';
    }
    if (body['text'] != null) {
      return 'single_text';
    }
    return 'default';
  }

  static void _enterCooldown(String scope) {
    _availabilityByScope[scope] = false;
    _cooldownUntilByScope[scope] = DateTime.now().add(cooldownDuration);
  }

  /// Force reset the cooldown (e.g. after connectivity restored).
  static void reset() {
    _availabilityByScope.clear();
    _cooldownUntilByScope.clear();
  }
}

/// Set of recognized ISO 639-1 language codes used for validation.
const Set<String> _validLanguageCodes = {
  'ar',
  'bg',
  'cs',
  'da',
  'de',
  'el',
  'en',
  'es',
  'et',
  'fi',
  'fr',
  'he',
  'hi',
  'hr',
  'hu',
  'id',
  'it',
  'ja',
  'ko',
  'lt',
  'lv',
  'nb',
  'nl',
  'pl',
  'pt',
  'ro',
  'ru',
  'sk',
  'sl',
  'sv',
  'th',
  'tr',
  'uk',
  'vi',
  'zh',
};

/// Returns true if [code] is a recognized language code.
bool isValidLanguageCode(String? code) {
  if (code == null || code.isEmpty) return false;
  return _validLanguageCodes.contains(normalizeLanguageCode(code));
}

String normalizeLanguageCode(String code) {
  // `translate-proxy` marks a row it is actively translating as
  // "<lang>#pending#<epochMs>".  Treat that as "<lang>": the claim describes
  // the same target language, so comparisons against the UI language must not
  // fail while the round trip is in flight — otherwise a perfectly readable
  // cached translation gets discarded and the preview blanks out.
  final c = stripPendingTranslationMarker(code) ?? '';
  if (c == 'iw') return 'he';
  if (c == 'in') return 'id';
  if (c == 'jv') return 'id';
  return c;
}

String guessLanguageCode(String text) {
  final t = text.trim();
  if (t.isEmpty) return 'und';

  // ---- Script-based detection for non-Latin scripts ----
  if (RegExp(r'[\u0590-\u05FF]').hasMatch(t)) return 'he';

  if (RegExp(r'[\u0600-\u06FF\u0750-\u077F]').hasMatch(t)) return 'ar';

  final hasCyrillic = RegExp(r'[\u0400-\u04FF]').hasMatch(t);
  if (hasCyrillic) {
    final lower = t.toLowerCase();
    const ukWords = {'є', 'ї', 'ґ', 'щ'};
    const bgWords = {'ъ'};
    if (ukWords.any((w) => lower.contains(w))) return 'uk';
    if (bgWords.any((w) => lower.contains(w))) return 'bg';
    return 'ru';
  }

  final hasDevanagari = RegExp(r'[\u0900-\u097F]').hasMatch(t);
  if (hasDevanagari) return 'hi';

  final hasThai = RegExp(r'[\u0E00-\u0E7F]').hasMatch(t);
  if (hasThai) return 'th';

  final hasGreek = RegExp(r'[\u0370-\u03FF]').hasMatch(t);
  if (hasGreek) return 'el';

  // CJK character ranges
  final hasHan = RegExp(r'[\u4E00-\u9FFF]').hasMatch(t);
  if (hasHan) {
    final hasHangul = RegExp(r'[\uAC00-\uD7AF]').hasMatch(t);
    if (hasHangul) return 'ko';
    final hasKatakana = RegExp(r'[\u30A0-\u30FF]').hasMatch(t);
    final hasHiragana = RegExp(r'[\u3040-\u309F]').hasMatch(t);
    if (hasKatakana || hasHiragana) return 'ja';
    return 'zh';
  }

  // ---- Word-frequency-based detection for Latin-script languages ----
  final lower = t.toLowerCase();
  final hasSpanishMarks =
      lower.contains('¿') ||
      lower.contains('¡') ||
      lower.contains('ñ') ||
      lower.contains('á') ||
      lower.contains('é') ||
      lower.contains('í') ||
      lower.contains('ó') ||
      lower.contains('ú') ||
      lower.contains('ü');
  if (hasSpanishMarks) return 'es';

  final words = lower
      .replaceAll(RegExp(r'[^\p{L}\s]', unicode: true), ' ')
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList();

  if (words.isEmpty) return 'und';

  const esCommon = <String>{
    'hola',
    'que',
    'cómo',
    'como',
    'estás',
    'estas',
    'gracias',
    'por',
    'favor',
    'vale',
    'bien',
    'buenos',
    'buenas',
    'donde',
    'dónde',
    'cuando',
    'cuándo',
    'porque',
    'porqué',
    'pero',
    'entonces',
    'también',
    'mucho',
    'aquí',
    'ahora',
    'siempre',
    'nunca',
    'todo',
    'sobre',
    'entre',
    'después',
    'antes',
    'si',
    'sí',
    'no',
    'de',
    'la',
    'el',
    'y',
    'en',
    'para',
    'con',
    'una',
    'un',
    'yo',
    'tu',
    'tú',
    'te',
    'me',
    'lo',
    'le',
    'se',
    'del',
    'las',
    'los',
    'mas',
    'más',
  };

  const enCommon = <String>{
    'hi',
    'hello',
    'hey',
    'thanks',
    'thank',
    'you',
    'are',
    'is',
    'am',
    'to',
    'of',
    'in',
    'for',
    'on',
    'with',
    'and',
    'the',
    'a',
    'an',
    'i',
    'we',
    'me',
    'my',
    'your',
    'our',
    'ok',
    'okay',
    'yes',
    'no',
    'this',
    'that',
    'it',
    'its',
    'have',
    'has',
    'had',
    'do',
    'does',
    'did',
    'was',
    'were',
    'be',
    'been',
    'will',
    'would',
    'could',
    'should',
    'can',
    'may',
    'might',
    'not',
    'or',
    'but',
    'if',
    'so',
    'up',
    'out',
    'all',
    'just',
    'about',
    'what',
    'when',
    'where',
    'who',
    'why',
    'how',
    'let',
    'get',
    'got',
    'see',
    'look',
    'come',
    'make',
    'know',
    'think',
    'tell',
    'give',
    'like',
    'love',
    'want',
    'need',
    'here',
    'there',
    'now',
    'then',
    'some',
    'any',
    'more',
    'really',
    'very',
    'too',
    'also',
    'well',
    'good',
    'great',
    'nice',
    'sure',
    'right',
    'going',
    'go',
    'went',
    'done',
    'back',
    'still',
    'even',
    'much',
    'many',
    'than',
  };

  const frCommon = <String>{
    'bonjour',
    'salut',
    'merci',
    's\'il',
    'vous',
    'plaît',
    's’il',
    'je',
    'tu',
    'il',
    'elle',
    'nous',
    'ils',
    'elles',
    'est',
    'sont',
    'ai',
    'as',
    'a',
    'avons',
    'avez',
    'ont',
    'ce',
    'cet',
    'cette',
    'ces',
    'mon',
    'ton',
    'son',
    'ma',
    'ta',
    'sa',
    'mes',
    'tes',
    'ses',
    'nos',
    'vos',
    'leurs',
    'le',
    'la',
    'les',
    'un',
    'une',
    'des',
    'du',
    'de',
    'au',
    'aux',
    'et',
    'ou',
    'mais',
    'donc',
    'car',
    'ni',
    'que',
    'qui',
    'quoi',
    'dont',
    'où',
    'comment',
    'pourquoi',
    'pas',
    'plus',
    'très',
    'bien',
    'oui',
    'non',
    'avec',
    'dans',
    'sur',
    'pour',
    'par',
    'entre',
    'sans',
    'chez',
    'faire',
    'fait',
    'peut',
    'veux',
    'vais',
    'suis',
  };

  const deCommon = <String>{
    'hallo',
    'tschüss',
    'danke',
    'bitte',
    'guten',
    'morgen',
    'abend',
    'nachts',
    'tag',
    'ich',
    'du',
    'er',
    'sie',
    'es',
    'wir',
    'ihr',
    'Sie',
    'ist',
    'sind',
    'bin',
    'bist',
    'hat',
    'hast',
    'haben',
    'habe',
    'ein',
    'eine',
    'einen',
    'einer',
    'eines',
    'der',
    'die',
    'das',
    'den',
    'dem',
    'des',
    'einem',
    'und',
    'oder',
    'aber',
    'denn',
    'weil',
    'wenn',
    'auch',
    'nicht',
    'ja',
    'nein',
    'doch',
    'schon',
    'noch',
    'mal',
    'sehr',
    'gut',
    'viel',
    'wie',
    'was',
    'wer',
    'wem',
    'wen',
    'wo',
    'warum',
    'wann',
    'mit',
    'nach',
    'vor',
    'bei',
    'aus',
    'von',
    'zu',
    'auf',
    'an',
    'in',
    'über',
    'unter',
    'für',
    'gegen',
    'um',
    'durch',
    'ohne',
  };

  const itCommon = <String>{
    'ciao',
    'buongiorno',
    'buonasera',
    'arrivederci',
    'grazie',
    'prego',
    'per',
    'favore',
    'come',
    'stai',
    'sto',
    'bene',
    'io',
    'tu',
    'lui',
    'lei',
    'noi',
    'voi',
    'loro',
    'sono',
    'sei',
    'è',
    'siamo',
    'siete',
    'hanno',
    'ho',
    'hai',
    'ha',
    'abbiamo',
    'avete',
    'il',
    'lo',
    'la',
    'i',
    'gli',
    'le',
    'un',
    'uno',
    'una',
    'del',
    'dello',
    'della',
    'dei',
    'degli',
    'delle',
    'di',
    'a',
    'da',
    'in',
    'con',
    'su',
    'tra',
    'fra',
    'e',
    'o',
    'ma',
    'che',
    'cosa',
    'non',
    'si',
    'sì',
    'molto',
    'tanto',
    'qui',
    'lì',
    'adesso',
    'ora',
    'sempre',
    'mai',
    'bello',
    'bella',
    'buono',
    'bravo',
  };

  const ptCommon = <String>{
    'olá',
    'oi',
    'tchau',
    'obrigado',
    'obrigada',
    'por',
    'favor',
    'bem',
    'bom',
    'boa',
    'como',
    'você',
    'voce',
    'está',
    'esta',
    'sou',
    'é',
    'são',
    'estou',
    'estamos',
    'estão',
    'tem',
    'têm',
    'muito',
    'aqui',
    'agora',
    'sempre',
    'nunca',
    'sim',
    'não',
    'nao',
    'talvez',
    'tudo',
    'mais',
    'menos',
    'já',
    'depois',
    'antes',
    'entre',
    'sobre',
    'para',
    'com',
    'sem',
    'porque',
    'que',
    'o',
    'a',
    'os',
    'as',
    'um',
    'uma',
    'uns',
    'umas',
    'do',
    'da',
    'dos',
    'das',
    'no',
    'na',
    'nos',
    'nas',
    'ao',
    'aos',
    'à',
    'às',
    'de',
    'em',
    'eu',
    'tu',
    'ele',
    'ela',
    'nós',
    'vos',
    'eles',
    'elas',
    'me',
    'te',
    'se',
    'lhe',
    'lhes',
    'seu',
    'sua',
    'seus',
    'suas',
  };

  const nlCommon = <String>{
    'de',
    'het',
    'een',
    'van',
    'voor',
    'met',
    'op',
    'niet',
    'dat',
    'maar',
    'ook',
    'zijn',
    'heeft',
    'worden',
    'zal',
    'kunnen',
    'moeten',
    'willen',
    'gaan',
    'goed',
    'veel',
    'nog',
    'hier',
    'daar',
    'waar',
    'zoals',
    'tussen',
    'zonder',
    'door',
    'naar',
    'uit',
    'over',
    'onder',
    'wel',
    'geen',
  };

  const plCommon = <String>{
    'się',
    'jest',
    'są',
    'mam',
    'masz',
    'mieć',
    'być',
    'będzie',
    'był',
    'ten',
    'ta',
    'to',
    'tego',
    'dla',
    'przez',
    'przy',
    'co',
    'jak',
    'gdzie',
    'kiedy',
    'kto',
    'czy',
    'ale',
    'że',
    'więc',
    'bo',
    'lub',
    'bardzo',
    'dobrze',
    'tak',
    'jeszcze',
    'już',
    'tylko',
    'może',
    'zawsze',
  };

  const svCommon = <String>{
    'och',
    'att',
    'det',
    'som',
    'jag',
    'är',
    'har',
    'på',
    'med',
    'för',
    'till',
    'inte',
    'var',
    'den',
    'om',
    'av',
    'kan',
    'men',
    'sig',
    'från',
    'upp',
    'ut',
    'över',
    'under',
    'efter',
    'före',
    'mellan',
    'blir',
    'ska',
    'skulle',
    'kunna',
    'måste',
    'bra',
    'mycket',
    'också',
  };

  const nbCommon = <String>{
    'og',
    'å',
    'det',
    'er',
    'som',
    'jeg',
    'har',
    'på',
    'med',
    'for',
    'til',
    'ikke',
    'var',
    'den',
    'om',
    'av',
    'kan',
    'men',
    'seg',
    'fra',
    'opp',
    'ut',
    'over',
    'under',
    'etter',
    'blir',
    'skal',
    'skulle',
    'kunne',
    'må',
  };

  const daCommon = <String>{
    'og',
    'at',
    'det',
    'er',
    'som',
    'jeg',
    'har',
    'på',
    'med',
    'for',
    'til',
    'ikke',
    'var',
    'den',
    'om',
    'af',
    'kan',
    'men',
    'sig',
    'fra',
    'op',
    'ud',
    'over',
    'under',
    'efter',
    'blive',
    'skal',
    'skulle',
    'kunne',
    'må',
  };

  const fiCommon = <String>{
    'ja',
    'on',
    'se',
    'ei',
    'että',
    'olla',
    'tämä',
    'hän',
    'joka',
    'mutta',
    'kanssa',
    'myös',
    'kun',
    'jos',
    'tai',
    'niin',
    'vain',
    'kuten',
    'paljon',
    'hyvä',
    'aina',
    'täällä',
    'siellä',
    'nyt',
    'sitten',
    'koska',
    'vielä',
    'mikä',
    'mitä',
    'kuka',
    'missä',
    'milloin',
    'miksi',
    'miten',
  };

  const csCommon = <String>{
    'se',
    'je',
    'jsou',
    'být',
    'bude',
    'byl',
    'ten',
    'ta',
    'to',
    'pro',
    'přes',
    'při',
    'co',
    'jak',
    'kde',
    'kdy',
    'kdo',
    'ale',
    'že',
    'proto',
    'nebo',
    'moc',
    'dobře',
    'ano',
    'ještě',
    'už',
    'jen',
    'také',
    'protože',
    'může',
  };

  const roCommon = <String>{
    'și',
    'pe',
    'la',
    'cu',
    'din',
    'pentru',
    'este',
    'sunt',
    'am',
    'ai',
    'are',
    'avem',
    'au',
    'poate',
    'trebuie',
    'vrea',
    'pot',
    'fac',
    'merge',
    'bun',
    'bine',
    'mult',
    'foarte',
    'aici',
    'acum',
    'după',
    'unde',
    'când',
    'cum',
    'cine',
  };

  const huCommon = <String>{
    'és',
    'a',
    'az',
    'egy',
    'van',
    'nem',
    'igen',
    'hogy',
    'ez',
    'azt',
    'itt',
    'ott',
    'most',
    'akkor',
    'hol',
    'ki',
    'mit',
    'miért',
    'de',
    'mert',
    'vagy',
    'nagyon',
    'jó',
    'rossz',
    'sok',
    'mindig',
    'soha',
    'még',
    'már',
    'csak',
  };

  const trCommon = <String>{
    've',
    'bir',
    'bu',
    'var',
    'yok',
    'evet',
    'hayır',
    'çok',
    'iyi',
    'nasıl',
    'ne',
    'nerede',
    'neden',
    'kim',
    'hangi',
    'ama',
    'çünkü',
    'veya',
    'ile',
    'için',
    'gibi',
    'kadar',
    'sonra',
    'önce',
    'içinde',
    'hep',
    'hiç',
    'daha',
    'en',
    'sadece',
  };

  const idCommon = <String>{
    'dan',
    'di',
    'ke',
    'dari',
    'dengan',
    'untuk',
    'pada',
    'adalah',
    'ini',
    'itu',
    'ada',
    'saya',
    'kamu',
    'dia',
    'kami',
    'kita',
    'mereka',
    'tidak',
    'sangat',
    'baik',
    'bagaimana',
    'apa',
    'di mana',
    'kapan',
    'mengapa',
    'siapa',
    'yang',
    'tetapi',
    'karena',
    'atau',
  };

  const viCommon = <String>{
    'và',
    'của',
    'các',
    'có',
    'không',
    'là',
    'với',
    'cho',
    'trong',
    'một',
    'người',
    'này',
    'đó',
    'những',
    'được',
    'đã',
    'sẽ',
    'đang',
    'rất',
    'nhưng',
    'hoặc',
    'vì',
    'nên',
    'phải',
    'tại',
    'ở',
    'từ',
    'vào',
    'ra',
    'cũng',
  };

  final wordSets = <String, Set<String>>{
    'es': esCommon,
    'en': enCommon,
    'fr': frCommon,
    'de': deCommon,
    'it': itCommon,
    'pt': ptCommon,
    'nl': nlCommon,
    'pl': plCommon,
    'sv': svCommon,
    'nb': nbCommon,
    'da': daCommon,
    'fi': fiCommon,
    'cs': csCommon,
    'ro': roCommon,
    'hu': huCommon,
    'tr': trCommon,
    'id': idCommon,
    'vi': viCommon,
  };

  final scores = <String, int>{};
  for (final lang in wordSets.keys) {
    scores[lang] = 0;
  }

  for (final w in words) {
    for (final entry in wordSets.entries) {
      if (entry.value.contains(w)) {
        scores[entry.key] = scores[entry.key]! + 1;
      }
    }
  }

  // Sort by score descending
  final sorted = scores.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));

  final best = sorted[0];
  final second = sorted[1];

  if (best.value == 0) return 'en';

  // For short messages (1-3 words), check if any word is unique to a language
  if (words.length <= 3) {
    for (final w in words) {
      final count = wordSets.entries.where((e) => e.value.contains(w)).length;
      if (count == 1) return best.key;
    }
  }

  // Strong dominance: top score >= 3 and at least 2x the second
  if (best.value >= 3 && best.value >= second.value * 2) return best.key;

  // Solo match: only one language scored
  if (best.value >= 2 && second.value == 0) return best.key;

  // Percentage-based: at least 20% of words matched
  if (best.value >= 2 && best.value / words.length >= 0.2) return best.key;

  // Single word that matched exactly one language
  if (best.value == 1 && second.value == 0) return best.key;

  return 'en';
}

// 1. Define the abstract interface (the "contract")
abstract class TranslationService {
  Future<String> identifyLanguage(String text);
  Future<bool> isModelDownloaded(String langCode);
  Future<bool> downloadModel(String langCode);

  /// Translate text from source to target language.
  /// Gender steering (any language pair): [speakerGender] is the message
  /// author's gender, [recipientGender] the addressee's gender. Accepted
  /// values: 'male' / 'female' (also 'gender_male' etc.); anything else
  /// (non-binary, unknown, empty) is omitted rather than guessed. The
  /// platform services forward this as DeepL's sanctioned unbilled `context`
  /// input — DeepL has no dedicated gender parameter. Chat history does not
  /// use this path (the edge function derives both genders server-side from
  /// the match), so existing cached translations stay valid.
  Future<String> translateText(
    String text,
    String sourceLang,
    String targetLang, {
    String? recipientGender,
    String? speakerGender,
  });
  void dispose();
}

// 2. Create the provider
final translationServiceProvider = Provider<TranslationService>((ref) {
  // Use the imported platform-specific service
  final service = getPlatformTranslationService();

  if (kIsWeb) {
  } else {}

  ref.onDispose(() => service.dispose());
  return service;
});

// Platform-specific factory function - this gets resolved by the conditional import above
// The imported file provides getPlatformTranslationService() which internally calls the right platform-specific function

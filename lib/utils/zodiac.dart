String? calculateZodiacSign(DateTime? date) {
  if (date == null) return null;
  final month = date.month;
  final day = date.day;

  if ((month == 3 && day >= 21) || (month == 4 && day <= 19)) return 'aries';
  if ((month == 4 && day >= 20) || (month == 5 && day <= 20)) return 'taurus';
  if ((month == 5 && day >= 21) || (month == 6 && day <= 20)) return 'gemini';
  if ((month == 6 && day >= 21) || (month == 7 && day <= 22)) return 'cancer';
  if ((month == 7 && day >= 23) || (month == 8 && day <= 22)) return 'leo';
  if ((month == 8 && day >= 23) || (month == 9 && day <= 22)) return 'virgo';
  if ((month == 9 && day >= 23) || (month == 10 && day <= 22)) return 'libra';
  if ((month == 10 && day >= 23) || (month == 11 && day <= 21)) {
    return 'scorpio';
  }
  if ((month == 11 && day >= 22) || (month == 12 && day <= 21)) {
    return 'sagittarius';
  }
  if ((month == 12 && day >= 22) || (month == 1 && day <= 19)) {
    return 'capricorn';
  }
  if ((month == 1 && day >= 20) || (month == 2 && day <= 18)) return 'aquarius';
  if ((month == 2 && day >= 19) || (month == 3 && day <= 20)) return 'pisces';
  return null;
}

String zodiacIcon(String sign) {
  switch (sign) {
    case 'aries':
      return '\u2648';
    case 'taurus':
      return '\u2649';
    case 'gemini':
      return '\u264A';
    case 'cancer':
      return '\u264B';
    case 'leo':
      return '\u264C';
    case 'virgo':
      return '\u264D';
    case 'libra':
      return '\u264E';
    case 'scorpio':
      return '\u264F';
    case 'sagittarius':
      return '\u2650';
    case 'capricorn':
      return '\u2651';
    case 'aquarius':
      return '\u2652';
    case 'pisces':
      return '\u2653';
    default:
      return '';
  }
}

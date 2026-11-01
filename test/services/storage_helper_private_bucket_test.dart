import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/services/storage_helper.dart';

void main() {
  group('StorageHelper.isPrivateBucket', () {
    // Supabase answers 400 for /storage/v1/object/public/<bucket>/... on a
    // private bucket, so the image layer must never build that URL shape.
    test('recognises every private bucket', () {
      expect(
        StorageHelper.isPrivateBucket(),
        isTrue,
        reason: 'no bucket means the default profile-photos bucket',
      );
      expect(StorageHelper.isPrivateBucket('profile-photos'), isTrue);
      expect(StorageHelper.isPrivateBucket('verification-photos'), isTrue);
      expect(StorageHelper.isPrivateBucket('profile-edit-attachments'), isTrue);
      expect(StorageHelper.isPrivateBucket('meetup-spot'), isTrue);
      expect(StorageHelper.isPrivateBucket('  profile-photos  '), isTrue);
      expect(StorageHelper.isPrivateBucket(''), isTrue);
    });

    test('leaves unknown buckets public', () {
      expect(StorageHelper.isPrivateBucket('public-assets'), isFalse);
      expect(StorageHelper.isPrivateBucket('avatars'), isFalse);
    });
  });
}

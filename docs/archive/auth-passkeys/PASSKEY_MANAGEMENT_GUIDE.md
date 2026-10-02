# Passkey Management Guide

## Overview

Passkeys provide a modern, secure, and passwordless authentication method. Users can now manage their passkeys through the Settings screen, including adding multiple passkeys and removing all passkeys when needed.

## Passkey Removal Feature

### When a User Needs to Remove a Passkey

Users might want to remove all registered passkeys in the following scenarios:

1. **Lost or Stolen Device**
   - If a device containing the user's passkey is lost or stolen
   - Removing passkeys prevents unauthorized access using that device
   - User can then re-establish secure access with another device

2. **Security Concern**
   - Upon suspecting unauthorized access to their account
   - As part of a security audit or incident response
   - If they believe a device has been compromised

3. **Device Cleanup**
   - Decommissioning an old device (phone, laptop, security key)
   - Before selling or giving away a device
   - When resetting a device to factory settings

4. **Too Many Passkeys**
   - Accumulated passkeys from testing or previous devices
   - Cleaning up unused/forgotten passkeys for security hygiene

5. **Account Lockout Recovery**
   - If the user can't access any registered passkeys
   - Allows them to revert to password-based authentication temporarily
   - Gives them a recovery path if all their passkeys are inaccessible

### How the Feature Works

In Settings:
- Users can see their passkey status
- A "Remove Passkey" button removes ALL registered passkeys
- A confirmation dialog warns the user about the consequences
- After removal, the user must sign in using password or other methods
- User can then register new passkeys from a trusted device

## Why Users Need Multiple Passkeys

### 1. **Device Redundancy & Backup**

**Scenario:** Sarah has a MacBook Pro with a passkey stored in iCloud Keychain. She also has an iPhone with the same passkey synced via Family Keychain.

**Benefit:** If her MacBook is stolen, she can still sign in using her iPhone, then remove the stolen MacBook's passkey from her account settings.

---

### 2. **Different Devices with Different Security Postures**

**Scenario:** Marcus has:
- A secure home desktop PC (Windows, BitLocker enabled, corporate-grade security)
- A work laptop (with full corporate MDM enforcement)
- A personal smartphone (regular consumer phone)

**Benefit:** Each device gets its own passkey tied to its local biometric/security system. If any device is compromised, the user can remove just that passkey, or remove all and re-register only the secure ones.

---

### 3. **Platform-Specific Passkeys**

**Scenario:** Jennifer has:
- iPhone with Face ID passkey
- Windows laptop with Windows Hello passkey (facial recognition)
- Android phone with fingerprint passkey

**Benefit:** Each platform stores passkeys differently—iOS uses Secure Enclave, Windows uses TPM, Android uses hardware keystore. Multiple passkeys provide defense-in-depth across different security architectures.

---

### 4. **Device Aging & Serial Replacement**

**Scenario:** A user gets a new iPhone annually and wants to update their passkeys.

**Flow:**
1. Set up new iPhone with a new passkey (for the new device)
2. Keep old iPhone's passkey active as backup
3. When satisfied the new passkey works reliably, remove the old iPhone's passkey
4. If new iPhone fails, can always fall back to password until getting a new device

**Benefit:** Gradual, safe migration between devices without account lockout.

---

### 5. **Family or Shared Account Scenarios**

**Scenario:** A couple manages a shared MatchMe account for event planning. Both have their devices registered with separate passkeys.

**Benefit:** Either person can sign in securely. If one person's phone is lost, the other can still access the account while the first person re-establishes their passkey on a new device.

---

### 6. **Security Key Redundancy (Future Enhancement)**

**Scenario:** A security-conscious user has:
- Primary U2F/FIDO2 security key (YubiKey)
- Backup hardware security key
- Passkey on trusted personal device

**Benefit:** Defense in depth—even if the primary key is lost, backups exist. Multiple passkeys mean no single point of failure.

---

### 7. **Gradual Migration from Password**

**Timeline:**
- Week 1: User adds first passkey to a new phone
- Week 2: User adds second passkey to their laptop
- Week 3: User removes password-only fallback, keeping both passkeys

**Benefit:** Reduces lockout risk during migration. If they can't use one device, they have a backup.

---

### 8. **Geographic Redundancy with Synced Passkeys**

**Scenario:** Jake travels internationally and carries:
- Main device (MacBook sync'd with cloud)
- Local backup device (iPad) with cloud sync

**Benefit:** Both devices have the same passkey (synced via iCloud/Play). If main device fails during travel, backup device works seamlessly.

---

## Implementation Details

### Backend Requirements

For passkey removal to work, the server must implement the following RPC:

```sql
CREATE OR REPLACE FUNCTION revoke_all_passkeys(p_user_id UUID)
RETURNS VOID AS $$
BEGIN
  -- Verify user is authenticated and removing their own passkeys
  IF auth.uid() != p_user_id THEN
    RAISE EXCEPTION 'Not authorized to revoke passkeys for other users';
  END IF;

  -- Delete all webauthn credentials for this user
  DELETE FROM webauthn_credentials 
  WHERE user_id = p_user_id;

  -- Optional: Log the revocation event
  INSERT INTO audit_log (user_id, action, timestamp)
  VALUES (p_user_id, 'passkey_revocation', NOW());

  -- Optional: Notify user via email about passkey removal
  -- (implementation depends on email service)
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

GRANT EXECUTE ON FUNCTION revoke_all_passkeys(UUID) TO authenticated;
```

### Frontend Implementation

The app provides:

1. **Passkey Status View** (Settings > Passkeys)
   - Shows current passkey configuration
   - Status indicators (enabled, disabled, unsupported)

2. **Add Passkey Button**
   - Initiates WebAuthn registration ceremony
   - Offers "Add Another" if passkey already exists

3. **Remove Passkey Button** ← NEW
   - Opens confirmation dialog (warns about consequences)
   - Calls `PasskeyAuthService.revokeAllPasskeys()`
   - Shows success/error feedback
   - Refreshes auth method status

### Error Recovery

If passkey removal fails:

- User retains all existing passkeys
- Error message displayed with retry option
- User can fall back to password authentication

If removal succeeds but user is locked out:

- They can use any password-based auth method to re-establish access
- They shouldregister new passkeys immediately
- Support team can verify identity and assist if needed

## User Education

### Best Practices

1. **Keep multiple passkeys** on different devices for redundancy
2. **Regular audit**: Review registered devices in Settings periodically
3. **Immediate removal**: Remove passkeys from lost/stolen devices immediately
4. **Backup registrations**: When adding a new device, wait a few days before removing old device's passkey
5. **Test recovery**: Try signing in from different devices to verify passkeys work

### When NOT to Remove Passkeys

❌ Don't remove passkeys if you only have one registered device (you'll be locked out)
❌ Don't remove passkeys unless you have another auth method (password) available
❌ Don't remove passkeys in production without testing first

## Future Enhancements

1. **Selective Passkey Removal**
   - View list of registered devices/passkeys
   - Remove individual passkeys instead of all at once

2. **Device Naming**
   - Let users label passkeys ("Work Laptop", "Personal iPhone")
   - Make selective removal easier

3. **Passkey Expiration**
   - Auto-expire unused passkeys after 90 days
   - Prompt user to re-register from that device

4. **Passkey Sharing**
   - Share passkey access with family members for account recovery
   - Requires server-side multi-factor approval

5. **Passkey Analytics**
   - Show which devices have been used recently
   - Alert on new passkey registrations
   - Geographic/IP tracking for unusual registrations

## Testing Checklist

- [ ] Add passkey from Device A
- [ ] Add passkey from Device B
- [ ] Sign in with passkey from Device A
- [ ] Sign in with passkey from Device B
- [ ] Remove all passkeys while signed in
- [ ] Verify can't sign in with either passkey
- [ ] Sign in with password
- [ ] Re-register new passkey
- [ ] Verify new passkey works
- [ ] Verify removal dialog shows correct warning text
- [ ] Verify cancel button preserves passkeys
- [ ] Verify success message after removal
- [ ] Verify error handling if RPC fails

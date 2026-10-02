import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:purchases_ui_flutter/purchases_ui_flutter.dart';

class PaymentService {
  static final PaymentService _instance = PaymentService._internal();
  factory PaymentService() => _instance;
  PaymentService._internal();

  bool _isInitialized = false;
  bool _isWebMode = false;

  /// Check if running in web mode
  bool get isWebMode => _isWebMode;

  /// Check if the SDK is initialized
  bool get isInitialized => _isInitialized;

  /// Initialize RevenueCat SDK
  Future<void> init() async {
    if (_isInitialized) return;

    String? apiKey;

    if (kIsWeb) {
      // Web mode - use web-specific test configuration
      apiKey = dotenv.env['REVENUECAT_API_KEY_WEB'];
      if (apiKey == null || apiKey.isEmpty) {
        print('⚠️ RevenueCat Web API Key not found. Using web test mode.');
        // Enable web test mode for development
        _isWebMode = true;
        _isInitialized = true;
        print('✅ PaymentService initialized in WEB TEST MODE');
        return;
      }
    } else {
      // Mobile mode
      if (Platform.isAndroid) {
        apiKey = dotenv.env['REVENUECAT_API_KEY_ANDROID'];
      } else if (Platform.isIOS) {
        apiKey = dotenv.env['REVENUECAT_API_KEY_IOS'];
      }
    }

    if (apiKey == null || apiKey.isEmpty) {
      print('⚠️ RevenueCat API Key not found. Payments will not work.');
      return;
    }

    try {
      await Purchases.setLogLevel(LogLevel.debug);

      PurchasesConfiguration configuration = PurchasesConfiguration(apiKey);
      await Purchases.configure(configuration);

      _isInitialized = true;
      _isWebMode = kIsWeb;
      print('✅ PaymentService initialized (web: $kIsWeb)');
    } catch (e) {
      print('❌ Failed to initialize PaymentService: $e');
      // If web fails, enable test mode as fallback
      if (kIsWeb) {
        _isWebMode = true;
        _isInitialized = true;
        print(
          '✅ PaymentService initialized in WEB TEST MODE (fallback after error)',
        );
      }
    }
  }

  /// Login to RevenueCat with the user's ID
  Future<void> login(String userId) async {
    if (!_isInitialized) return;

    // Web test mode - no actual RevenueCat login needed
    if (_isWebMode) {
      print('✅ PaymentService web test mode: simulated login');
      return;
    }

    try {
      LogInResult result = await Purchases.logIn(userId);
      print('✅ PaymentService logged in. Created: ${result.created}');
    } catch (e) {
      print('❌ PaymentService login failed: $e');
    }
  }

  /// Logout from RevenueCat
  Future<void> logout() async {
    if (!_isInitialized) return;

    // Web test mode - no actual logout needed
    if (_isWebMode) {
      print('✅ PaymentService web test mode: simulated logout');
      return;
    }

    try {
      await Purchases.logOut();
      print('✅ PaymentService logged out');
    } catch (e) {
      print('❌ PaymentService logout failed: $e');
    }
  }

  /// Check if the user has a specific entitlement (access level)
  Future<bool> hasEntitlement(String entitlementId) async {
    if (!_isInitialized) return false;

    // Web test mode - entitlements are managed via Supabase, not RevenueCat
    if (_isWebMode) {
      print(
        '💰 PaymentService web test mode: entitlements checked via Supabase (not RevenueCat)',
      );
      return false; // Return false to allow Supabase-based subscription check
    }

    try {
      CustomerInfo customerInfo = await Purchases.getCustomerInfo();
      return customerInfo.entitlements.all[entitlementId]?.isActive ?? false;
    } catch (e) {
      print('❌ Failed to check entitlement: $e');
      return false;
    }
  }

  /// Get current subscription info
  Future<CustomerInfo?> getCustomerInfo() async {
    if (!_isInitialized) return null;

    // Web test mode - return simulated customer info
    if (_isWebMode) {
      print(
        '💰 PaymentService web test mode: returning simulated customer info',
      );
      // Return a minimal CustomerInfo for web testing
      // This allows the app to work in web mode for testing
      return null; // Returning null allows fallback to Supabase-based subscription
    }

    try {
      return await Purchases.getCustomerInfo();
    } catch (e) {
      print('❌ Failed to get customer info: $e');
      return null;
    }
  }

  /// Listen for customer info updates
  void addCustomerInfoUpdateListener(void Function(CustomerInfo) listener) {
    if (!_isInitialized) return;

    // Web test mode - customer info updates are not available
    if (_isWebMode) {
      print(
        '💰 PaymentService web test mode: customer info updates not available',
      );
      return;
    }

    Purchases.addCustomerInfoUpdateListener(listener);
  }

  /// Show the Paywall and handle the purchase flow automatically
  /// Returns true if a purchase was completed or restored successfully
  Future<bool> showPaywall() async {
    if (!_isInitialized) {
      print('⚠️ PaymentService not initialized');
      return false;
    }

    // Web test mode - RevenueCatUI is not available on web
    if (_isWebMode) {
      print(
        '💰 PaymentService web test mode: RevenueCatUI not available on web',
      );
      // Return false so the app can fall back to custom paywall
      return false;
    }

    try {
      // Present the default Paywall
      final paywallResult = await RevenueCatUI.presentPaywallIfNeeded("pro");
      print('💰 Paywall result: $paywallResult');

      // If the user purchased or restored, we should check their entitlements
      // Note: RevenueCatUI handles the purchase flow, but we return status for the app to react
      return paywallResult == PaywallResult.purchased ||
          paywallResult == PaywallResult.restored;
    } on PlatformException catch (e) {
      // Error handling
      print('❌ Paywall error: ${e.message}');
      return false;
    } catch (e) {
      print('❌ Unexpected paywall error: $e');
      return false;
    }
  }

  /// Purchase a specific package manually (if not using Paywall UI)
  Future<bool> purchasePackage(Package package) async {
    if (!_isInitialized) return false;

    // Web test mode - simulate successful purchase
    if (_isWebMode) {
      print('💰 PaymentService web test mode: simulating successful purchase');
      // In web test mode, we simulate a successful purchase
      // The actual subscription will be handled by the payment provider using Supabase
      return true;
    }

    try {
      // v9 update: purchasePackage is deprecated but purchase(PurchaseParams) is tricky to construct without docs
      // ignore: deprecated_member_use
      final purchaseResult = await Purchases.purchasePackage(package);

      final customerInfo = purchaseResult.customerInfo;

      // Check if any known entitlement is active
      final entitlements = customerInfo.entitlements.all;
      final isActive =
          (entitlements['platinum']?.isActive ?? false) ||
          (entitlements['gold']?.isActive ?? false) ||
          (entitlements['plus']?.isActive ?? false) ||
          (entitlements['pro']?.isActive ?? false);

      print(
        '💰 Purchase successful. Active entitlements: ${entitlements.keys.where((k) => entitlements[k]?.isActive ?? false).toList()}',
      );
      return isActive;
    } catch (e) {
      if (e is PlatformException) {
        var errorCode = PurchasesErrorHelper.getErrorCode(e);
        if (errorCode != PurchasesErrorCode.purchaseCancelledError) {
          print('❌ Purchase failed: $e');
        }
      }
      return false;
    }
  }

  /// Restore purchases
  Future<CustomerInfo?> restorePurchases() async {
    if (!_isInitialized) return null;

    // Web test mode - simulate restore (no-op for web testing)
    if (_isWebMode) {
      print('💰 PaymentService web test mode: simulated restore (no-op)');
      return null;
    }

    try {
      final customerInfo = await Purchases.restorePurchases();
      print('✅ Purchases restored');
      return customerInfo;
    } catch (e) {
      print('❌ Failed to restore purchases: $e');
      return null;
    }
  }

  /// Get available offerings (products)
  Future<Offerings?> getOfferings() async {
    if (!_isInitialized) return null;

    // Web test mode - return null (offerings not available in web test mode)
    // The app should fall back to subscription tiers from Supabase
    if (_isWebMode) {
      print(
        '💰 PaymentService web test mode: offerings not available (using Supabase tiers)',
      );
      return null;
    }

    try {
      return await Purchases.getOfferings();
    } catch (e) {
      print('❌ Failed to get offerings: $e');
      return null;
    }
  }
}

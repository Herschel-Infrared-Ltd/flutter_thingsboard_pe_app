import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:fluro/fluro.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:thingsboard_app/config/routes/router.dart';
import 'package:thingsboard_app/core/context/tb_context_widget.dart';
import 'package:thingsboard_app/core/logger/tb_logger.dart';
import 'package:thingsboard_app/locator.dart';
import 'package:thingsboard_app/modules/version/route/version_route.dart';
import 'package:thingsboard_app/modules/version/route/version_route_arguments.dart';
import 'package:thingsboard_app/thingsboard_client.dart';
import 'package:thingsboard_app/utils/services/device_info/i_device_info_service.dart';
import 'package:thingsboard_app/utils/services/endpoint/i_endpoint_service.dart';
import 'package:thingsboard_app/utils/services/firebase/i_firebase_service.dart';
import 'package:thingsboard_app/utils/services/layouts/i_layout_service.dart';
import 'package:thingsboard_app/utils/services/local_database/i_local_database_service.dart';
import 'package:thingsboard_app/utils/services/notification_service.dart';
import 'package:thingsboard_app/utils/services/overlay_service/i_overlay_service.dart';

import 'package:thingsboard_app/utils/services/wl_service.dart';
import 'package:universal_platform/universal_platform.dart';

part 'has_tb_context.dart';

class TbContext implements PopEntry {
  TbContext() {
    wlService = WlService(this);
  }
  bool isUserLoaded = false;
  final _isAuthenticated = ValueNotifier<bool>(false);
  List<TwoFaProviderInfo>? twoFactorAuthProviders;
  User? userDetails;
  AllowedPermissionsInfo? userPermissions;
  HomeDashboardInfo? homeDashboard;
  VersionInfo? versionInfo;
  StoreInfo? storeInfo;
  final IOverlayService _overlayService = getIt<IOverlayService>();
  final _deviceInfoService = getIt<IDeviceInfoService>();
  final _isLoadingNotifier = ValueNotifier<bool>(false);
  final _log = TbLogger();
  StreamSubscription? _appLinkStreamSubscription;
  final appLinks = AppLinks();

  bool _closeMainFirst = false;
  late bool _handleRootState;

  @override
  final canPopNotifier = ValueNotifier<bool>(false);

  @override
  void onPopInvoked(bool didPop) {
    onPopInvokedImpl(didPop);
  }

  @override
  void onPopInvokedWithResult(bool didPop, dynamic result) {
    onPopInvokedImpl(didPop, result);
  }

  late ThingsboardClient tbClient;
  late final WlService wlService;

 final RouteObserver<PageRoute> routeObserver = RouteObserver<PageRoute>();

  Listenable get isAuthenticatedListenable => _isAuthenticated;

  bool get isAuthenticated => _isAuthenticated.value;

  TbContextState? currentState;
  late final ThingsboardAppRouter thingsboardAppRouter = getIt();
  TbLogger get log => _log;
  final bottomNavigationTabChangedStream = StreamController<int>.broadcast();

  Future<void> init() async {
    _handleRootState = true;

    final endpoint = await getIt<IEndpointService>().getEndpoint();
    log.debug('TbContext::init() endpoint: $endpoint');

    tbClient = ThingsboardClient(
      endpoint,
      storage: getIt(),
      onUserLoaded: onUserLoaded,
      onError: onError,
      onLoadStarted: onLoadStarted,
      onLoadFinished: onLoadFinished,
      computeFunc: <Q, R>(callback, message) => compute(callback, message),
    );

    try {
      try {
        final initialUri = await appLinks.getInitialLink();
        _updateInitialNavigation(initialUri);
      } catch (e) {
        log.error('Failed to get initial uri: $e', e);
      }
      await tbClient.init();
      if (UniversalPlatform.isAndroid || UniversalPlatform.isIOS) {
        appLinks.uriLinkStream.listen(
          (Uri? uri) {
            _updateInitialNavigation(uri);
            handleInitialNavigation();
          },
          onError: (e) {
            log.error('Failed to get new initial uri: $e', e);
          },
        );
      }
    } catch (e, s) {
      log.error('Failed to init tbContext: $e', e, s);
      await onFatalError(e);
    }
  }

  Future<void> _updateInitialNavigation(Uri? initialUri) async {
    String? initialNavigation;

    if (initialUri != null && initialUri.path.isNotEmpty) {
      initialNavigation = initialUri.path;
      if (initialUri.hasQuery) {
        initialNavigation = '$initialNavigation?${initialUri.query}';
      }
      await getIt<ILocalDatabaseService>().setInitialAppLink(initialNavigation);
      log.debug('Initial navigation: $initialNavigation');
    }
  }

  Future<void> reInit({
    required String endpoint,
    required VoidCallback onDone,
    required ErrorCallback onAuthError,
  }) async {
    log.debug('TbContext:reinit()');

    _handleRootState = false;

    tbClient = ThingsboardClient(
      endpoint,
      storage: getIt(),
      onUserLoaded: () => onUserLoaded(onDone: onDone),
      onError: (error) {
        onAuthError(error);
        onError(error);
      },
      onLoadStarted: onLoadStarted,
      onLoadFinished: onLoadFinished,
      computeFunc: <Q, R>(callback, message) => compute(callback, message),
    );

    await tbClient.init();
  }

  Future<void> onFatalError(dynamic e) async {
    var message = e is ThingsboardError
        ? (e.message ?? 'Unknown error.')
        : 'Unknown error.';
    message = 'Fatal application error occured:\n$message.';
    await alert(title: 'Fatal error', message: message, ok: 'Close');
    logout();
  }

  void onError(ThingsboardError tbError) {
    log.error('onError', tbError, tbError.getStackTrace());
    _overlayService.showErrorNotification(tbError.message!);
  }

  void onLoadStarted() {
    log.debug('TbContext: On load started.');
    _isLoadingNotifier.value = true;
  }

  Future<void> onLoadFinished() async {
    log.debug('TbContext: On load finished.');
    _isLoadingNotifier.value = false;
  }

  Future<void> onUserLoaded({VoidCallback? onDone}) async {
    try {
      log.debug(
        'TbContext.onUserLoaded: isAuthenticated=${tbClient.isAuthenticated()}',
      );
      isUserLoaded = true;
      if (tbClient.isAuthenticated() && !tbClient.isPreVerificationToken()) {
        log.debug('authUser: ${tbClient.getAuthUser()}');
        if (tbClient.getAuthUser()!.userId != null) {
          try {
            userPermissions = await tbClient
                .getUserPermissionsService()
                .getAllowedPermissions();

            final mobileInfo =
                await tbClient.getMobileService().getUserMobileInfo(
                      MobileInfoQuery(
                        platformType: _deviceInfoService.getPlatformType(),
                        packageName: _deviceInfoService.getApplicationId(),
                      ),
                    );

            userDetails = mobileInfo?.user;
            homeDashboard = mobileInfo?.homeDashboardInfo;
            versionInfo = mobileInfo?.versionInfo;
            storeInfo = mobileInfo?.storeInfo;
            getIt<ILayoutService>().cachePageLayouts(
              mobileInfo?.pages,
              authority: tbClient.getAuthUser()!.authority,
            );
          } catch (e) {
            log.error('TbContext::onUserLoaded error $e');
            if (!_isConnectionError(e)) {
              logout();
            } else {
              rethrow;
            }
          }
        }
      } else {
        if (tbClient.isPreVerificationToken()) {
          log.debug('authUser: ${tbClient.getAuthUser()}');
          twoFactorAuthProviders = await tbClient
              .getTwoFactorAuthService()
              .getAvailableLoginTwoFaProviders();
        } else {
          twoFactorAuthProviders = null;
        }

        userDetails = null;
        userPermissions = null;
        homeDashboard = null;
        versionInfo = null;
        storeInfo = null;
      }

      _isAuthenticated.value =
          tbClient.isAuthenticated() && !tbClient.isPreVerificationToken();
      await wlService.updateWhiteLabeling();
      if (versionInfo != null && versionInfo?.minVersion != null) {
        if (_deviceInfoService.getAppVersion().versionInt() <
            (versionInfo!.minVersion?.versionInt() ?? 0)) {
          thingsboardAppRouter.navigateTo(
            VersionRoutes.updateRequiredRoutePath,
            clearStack: true,
            replace: true,
            routeSettings: RouteSettings(
              arguments: VersionRouteArguments(
                versionInfo: versionInfo!,
                storeInfo: storeInfo,
              ),
            ),
          );
          return;
        }
      }

      if (isAuthenticated) {
        onDone?.call();
      }

      if (_handleRootState) {
        await updateRouteState();
      }

      if (isAuthenticated) {
        if (getIt<IFirebaseService>().apps.isNotEmpty) {
          await NotificationService(tbClient, log, this).init();
        }
      }
    } catch (e, s) {
      log.error('TbContext.onUserLoaded: $e', e, s);

      if (_isConnectionError(e)) {
        final res = await confirm(
          title: 'Connection error',
          message: 'Failed to connect to server',
          ok: 'Retry',
        );
        if (res == true) {
          _overlayService.hideNotification();
          onUserLoaded();
        } else {
          thingsboardAppRouter.navigateTo(
            '/login',
            replace: true,
            clearStack: true,
            transition: TransitionType.fadeIn,
            transitionDuration: const Duration(milliseconds: 750),
          );
        }
      } else {
        thingsboardAppRouter.navigateTo(
          '/login',
          replace: true,
          clearStack: true,
          transition: TransitionType.fadeIn,
          transitionDuration: const Duration(milliseconds: 750),
        );
      }
    } finally {
      try {
        final link = await getIt<ILocalDatabaseService>().getInitialAppLink();
        thingsboardAppRouter.navigateByAppLink(link);
      } catch (e) {
        log.error('TbContext:getInitialUri() exception $e');
      }

      _appLinkStreamSubscription ??= appLinks.uriLinkStream.listen(
        (link) {
          thingsboardAppRouter.navigateByAppLink(link.toString());
        },
        onError: (err) {
          log.error('linkStream.listen $err');
        },
      );
    }
  }

  Future<void> logout({
    RequestConfig? requestConfig,
    bool notifyUser = true,
  }) async {
    log.debug('TbContext::logout($requestConfig, $notifyUser)');
    _handleRootState = true;

    if (getIt<IFirebaseService>().apps.isNotEmpty) {
      await NotificationService(tbClient, log, this).logout();
    }

    await tbClient.logout(
      requestConfig: requestConfig,
      notifyUser: notifyUser,
    );

    _appLinkStreamSubscription?.cancel();
    _appLinkStreamSubscription = null;
  }

  bool _isConnectionError(e) {
    return e is ThingsboardError &&
        e.errorCode == ThingsBoardErrorCode.general &&
        e.message == 'Unable to connect';
  }
///TODO: Mergeconflict here
  bool hasGenericPermission(Resource resource, Operation operation) {
    if (userPermissions != null) {
      return userPermissions!.hasGenericPermission(resource, operation);
    } else {
      return false;
    }
  }
///TODO: Mergeconflict here
  Future<bool> handleInitialNavigation() async {
    final initialNavigation =
        await getIt<ILocalDatabaseService>().getInitialAppLink();

    log.debug('TbContext::handleInitialNavigation() -> $initialNavigation');

    if (initialNavigation != null &&
        initialNavigation.startsWith('/signup/emailVerified')) {
      if (tbClient.isAuthenticated()) {
        tbClient.logout();
      } else {
       getIt<ThingsboardAppRouter>().navigateTo(
          initialNavigation,
          replace: true,
          clearStack: true,
          transition: TransitionType.fadeIn,
          transitionDuration: const Duration(milliseconds: 750),
        );
        getIt<ILocalDatabaseService>().deleteInitialAppLink();
      }
      return true;
    }

    return false;
  }

  Future<void> updateRouteState() async {
    log.debug(
      'TbContext:updateRouteState() ${currentState != null && currentState!.mounted}',
    );
    if (currentState != null) {
      if (!await handleInitialNavigation()) {
        if (tbClient.isAuthenticated() && !tbClient.isPreVerificationToken()) {
          final defaultDashboardId = _defaultDashboardId();
          if (defaultDashboardId != null) {
            final bool fullscreen = _userForceFullscreen();
            if (!fullscreen) {
              await thingsboardAppRouter.navigateToDashboard(defaultDashboardId, animate: false);
           thingsboardAppRouter.navigateTo(
                '/main',
                replace: true,
                closeDashboard: false,
                clearStack: true,
                transition: TransitionType.none,
              );
            } else {
               thingsboardAppRouter.navigateTo(
                '/fullscreenDashboard/$defaultDashboardId',
                replace: true,
                clearStack: true,
                transition: TransitionType.fadeIn,
              );
            }
          } else {
             thingsboardAppRouter.navigateTo(
              '/main',
              replace: true,
              clearStack: true,
              transition: TransitionType.fadeIn,
              transitionDuration: const Duration(milliseconds: 750),
            );
          }
        } else {
           thingsboardAppRouter.navigateTo(
            '/login',
            replace: true,
            clearStack: true,
            transition: TransitionType.fadeIn,
            transitionDuration: const Duration(milliseconds: 750),
          );
        }
      }
    }
  }

  String? _defaultDashboardId() {
    if (userDetails != null && userDetails!.additionalInfo != null) {
      return userDetails!.additionalInfo!['defaultDashboardId'].toString();
    }
    return null;
  }

  bool _userForceFullscreen() {
    return tbClient.getAuthUser()!.isPublic! ||
        (userDetails != null &&
            userDetails!.additionalInfo != null &&
            userDetails!.additionalInfo!['defaultDashboardFullscreen'] == true);
  }

  String userAgent() {
    String userAgent = 'Mozilla/5.0';
    if (UniversalPlatform.isAndroid) {
      userAgent +=
          ' (Linux; Android ${_deviceInfoService.getSystemVersion()}; ${_deviceInfoService.getDeviceModel()})';
    } else if (UniversalPlatform.isIOS) {
      userAgent += ' (${_deviceInfoService.getDeviceModel()})';
    }
    return '$userAgent AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/83.0.4103.106 Mobile Safari/537.36';
  }

  bool isHomePage() {
    if (currentState != null) {
      if (currentState is TbMainState) {
        final mainState = currentState! as TbMainState;
        return mainState.isHomePage();
      }
    }
    return false;
  }

  

  Future<T?> showFullScreenDialog<T>(Widget dialog, {BuildContext? context}) {
    return Navigator.of(context ?? currentState!.context).push<T>(
      MaterialPageRoute<T>(
        builder: (BuildContext context) {
          return dialog;
        },
        fullscreenDialog: true,
      ),
    );
  }
static showFullScreenDialogStatic<T>(
    BuildContext context,
    Widget dialog,) {
    return Navigator.of(context).push<T>(
      MaterialPageRoute<T>(
        builder: (BuildContext context) {
          return dialog;
        },
        fullscreenDialog: true,
      ),
    );
  }

  Future<void> onPopInvokedImpl<T>(bool didPop, [T? result]) async {
    if (didPop) {
      return;
    }

    if (await currentState?.willPop() == true) {
      if (currentState?.context != null &&
          currentState?.context.mounted == true) {
        // ignore: use_build_context_synchronously
        final navigator = Navigator.of(currentState!.context);
        if (navigator.canPop()) {
          navigator.pop(result);
        } else {
          SystemNavigator.pop();
        }
      }
    }
  }

  Future<void> alert({
    required String title,
    required String message,
    String ok = 'Ok',
  }) {
    return showDialog<bool>(
      context: currentState!.context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => thingsboardAppRouter.pop(null, context),
            child: Text(ok),
          ),
        ],
      ),
    );
  }

  Future<bool?> confirm({
    required String title,
    required String message,
    String cancel = 'Cancel',
    String ok = 'Ok',
  }) {
    return showDialog<bool>(
      context: currentState!.context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => getIt<ThingsboardAppRouter>().pop(false, context),
            child: Text(cancel),
          ),
          TextButton(
              onPressed: () => getIt<ThingsboardAppRouter>().pop(true, context),
              child: Text(ok)),
        ],
      ),
    );
  }
}

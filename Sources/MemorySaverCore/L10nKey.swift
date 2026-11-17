/// Every piece of user-visible text. The raw value is the key in the translation files
/// (`Resources/<language>.lproj/Localizable.strings`, or `.stringsdict` for plurals).
/// A test checks that every case has an entry in every language.
public enum L10nKey: String, CaseIterable, Sendable {
    // MARK: Popover: header
    case popoverMeasuringTitle = "popover.measuring.title"
    case popoverMeasuringDescription = "popover.measuring.description"
    case popoverUnavailableTitle = "popover.unavailable.title"
    case popoverHeaderMemory = "popover.header.memory"
    case popoverHeaderSwap = "popover.header.swap"
    case popoverPressureNormal = "popover.pressure.normal"
    case popoverPressureWarning = "popover.pressure.warning"
    case popoverPressureCritical = "popover.pressure.critical"

    // MARK: Popover: WindowServer
    case popoverWindowServerUnavailable = "popover.windowServer.unavailable"
    case popoverWindowServerSuspectsTitle = "popover.windowServer.suspectsTitle"
    /// Plural. Argument: the count (`Int`).
    case popoverWindowServerWindowCount = "popover.windowServer.windowCount"
    case popoverWindowServerSuspectsNote = "popover.windowServer.suspectsNote"

    // MARK: Popover: ranking
    case popoverRankingTitle = "popover.ranking.title"
    case popoverRankingHint = "popover.ranking.hint"
    /// Plural. Argument: the count (`Int`).
    case popoverRankingProcessCount = "popover.ranking.processCount"
    case popoverRankingRowHelpHide = "popover.ranking.rowHelp.hide"
    case popoverRankingRowHelpShow = "popover.ranking.rowHelp.show"
    case popoverRankingRowHint = "popover.ranking.rowHint"

    // MARK: Popover: footer
    case popoverFooterUpdated = "popover.footer.updated"
    case popoverFooterRefreshHelp = "popover.footer.refresh.help"
    case popoverFooterRefreshAccessibilityLabel = "popover.footer.refresh.accessibilityLabel"
    case popoverFooterSettingsHelp = "popover.footer.settings.help"
    case popoverFooterSettingsAccessibilityLabel = "popover.footer.settings.accessibilityLabel"
    case popoverFooterQuitHelp = "popover.footer.quit.help"
    case popoverFooterQuitAccessibilityLabel = "popover.footer.quit.accessibilityLabel"

    // MARK: Relaunch
    case relaunchButton = "relaunch.button"
    case relaunchConfirmTitle = "relaunch.confirm.title"
    case relaunchConfirmMessage = "relaunch.confirm.message"
    case relaunchConfirmButton = "relaunch.confirm.button"
    case relaunchConfirmCancel = "relaunch.confirm.cancel"
    case relaunchStatusWaiting = "relaunch.status.waiting"
    case relaunchStatusStopWaiting = "relaunch.status.stopWaiting"
    case relaunchStatusStopWaitingHelp = "relaunch.status.stopWaitingHelp"
    case relaunchStatusDismiss = "relaunch.status.dismiss"
    case relaunchStatusWithAppName = "relaunch.status.withAppName"
    case relaunchResultNotRunning = "relaunch.result.notRunning"
    case relaunchResultFailed = "relaunch.result.failed"
    case relaunchResultStoppedWaiting = "relaunch.result.stoppedWaiting"
    case relaunchResultWaitTimedOut = "relaunch.result.waitTimedOut"
    case relaunchResultQuitButNotReopened = "relaunch.result.quitButNotReopened"
    case relaunchErrorUnsupported = "relaunch.error.unsupported"
    case relaunchErrorAppNotFound = "relaunch.error.appNotFound"
    case relaunchErrorQuitRefused = "relaunch.error.quitRefused"

    // MARK: Growth
    case growthSinceLaunch = "growth.sinceLaunch"
    case growthSinceStartup = "growth.sinceStartup"
    case growthSinceMonitoringBegan = "growth.sinceMonitoringBegan"

    // MARK: Icon legend
    case legendButtonHelp = "legend.button.help"
    case legendButtonAccessibilityLabel = "legend.button.accessibilityLabel"
    case legendSectionMenuBar = "legend.section.menuBar"
    case legendMenuBarNormal = "legend.menuBar.normal"
    case legendMenuBarRecommendation = "legend.menuBar.recommendation"
    case legendMenuBarWarning = "legend.menuBar.warning"
    case legendMenuBarCritical = "legend.menuBar.critical"
    case legendSectionWindow = "legend.section.window"
    case legendWindowExpand = "legend.window.expand"
    case legendWindowRefresh = "legend.window.refresh"
    case legendWindowSettings = "legend.window.settings"
    case legendWindowQuit = "legend.window.quit"
    case legendSectionGrowth = "legend.section.growth"
    case legendGrowthNote = "legend.growth.note"
    case legendVersion = "legend.version"

    // MARK: History chart
    case chartTitle = "chart.title"
    case chartRangeDay = "chart.range.day"
    case chartRangeWeek = "chart.range.week"
    case chartRangeAccessibilityLabel = "chart.range.accessibilityLabel"
    case chartBaseline = "chart.baseline"
    case chartNotEnoughHistory = "chart.notEnoughHistory"
    case chartHelpShow = "chart.help.show"
    case chartHelpHide = "chart.help.hide"
    case chartAccessibilityHint = "chart.accessibilityHint"
    case chartSystemAccessibilityHint = "chart.system.accessibilityHint"

    // MARK: Updates
    case updateAvailable = "update.available"
    case updateDownload = "update.download"
    case settingsSectionUpdates = "settings.section.updates"
    case settingsUpdateCheckToggle = "settings.update.toggle"
    case settingsUpdateCheckNow = "settings.update.checkNow"
    case settingsUpdateChecking = "settings.update.checking"
    case settingsUpdateUpToDate = "settings.update.upToDate"
    case settingsUpdateFailed = "settings.update.failed"
    case settingsUpdateLastChecked = "settings.update.lastChecked"
    case settingsUpdateNeverChecked = "settings.update.neverChecked"

    // MARK: Settings
    case settingsWindowTitle = "settings.windowTitle"
    case settingsSectionThresholds = "settings.section.thresholds"
    case settingsThresholdAppFootprint = "settings.threshold.appFootprint"
    case settingsThresholdAppGrowth = "settings.threshold.appGrowth"
    case settingsThresholdWindowServerGrowth = "settings.threshold.windowServerGrowth"
    case settingsSectionNotifications = "settings.section.notifications"
    case settingsNotificationsToggle = "settings.notifications.toggle"
    case settingsNotificationsDenied = "settings.notifications.denied"
    case settingsLaunchAtLoginToggle = "settings.launchAtLogin.toggle"
    case settingsLaunchAtLoginError = "settings.launchAtLogin.error"
    case settingsLaunchAtLoginNeedsApproval = "settings.launchAtLogin.needsApproval"
    case settingsLaunchAtLoginOpenSettings = "settings.launchAtLogin.openSettings"
    case settingsLaunchAtLoginOutsideApplications = "settings.launchAtLogin.outsideApplications"
    case settingsSectionExclusions = "settings.section.exclusions"
    case settingsExclusionsEmpty = "settings.exclusions.empty"
    case settingsExclusionsRemove = "settings.exclusions.remove"
    case settingsExclusionsAddMenu = "settings.exclusions.addMenu"
    case settingsVersion = "settings.version"

    // MARK: Menu bar
    case menuBarAccessibilityLabel = "menuBar.accessibilityLabel"

    // MARK: Notification
    case notificationTitle = "notification.title"
    case notificationRelaunchApps = "notification.relaunchApps"
    case notificationWindowServer = "notification.windowServer"
    case notificationAppListSeparator = "notification.appListSeparator"
    case notificationSentenceSeparator = "notification.sentenceSeparator"

    // MARK: Errors
    case errorHistoryOpenFailed = "error.historyOpenFailed"
    case errorHistoryUnsaved = "error.historyUnsaved"
    case errorMemoryReadFailed = "error.memoryReadFailed"
    case errorHistoryAccessFailed = "error.historyAccessFailed"
}

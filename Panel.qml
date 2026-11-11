import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Ui as Ui
import qs.Commons
import qs.Commons as Palette

Item {
  id: root
  property var shell: null
  property QtObject service: null
  property bool isOpen: false
  readonly property alias opened: root.isOpen
  property Item popupAnchor: null
  property QtObject popupBar: null

  // Process and sampling state
  property bool sampling: false
  property int sampleCount: 0
  property int maxSamples: 3
  property string _localStatusMessage: "Idle"
  readonly property string statusMessage: (service && service.hasData) ? service.statusMessage : _localStatusMessage
  property string _localLastError: ""
  readonly property string lastError: (service && service.lastError !== "") ? service.lastError : _localLastError
  property bool _localHasData: false
  readonly property bool hasData: service ? service.hasData : _localHasData

  // Hardware telemetry from monitor.py
  property real _localCpu: 0.0
  readonly property real cpu: service ? service.cpu : _localCpu
  property real _localBusiestCore: 0.0
  readonly property real busiestCore: service ? service.busiestCore : _localBusiestCore
  property real _localGpu: 0.0
  readonly property real gpu: service ? service.gpu : _localGpu
  property real _localTemperature: 0.0
  readonly property real temperature: service ? service.temperature : _localTemperature
  property real _localBattery: 0.0
  readonly property real battery: service ? service.battery : _localBattery
  property real _localMemoryPressure: 0.0
  readonly property real memoryPressure: service ? service.memoryPressure : _localMemoryPressure
  property bool _localOnAc: false
  readonly property bool onAc: service ? service.onAc : _localOnAc

  // Recommendation engine state from policy.py
  property string _localCurrentTier: "--"
  readonly property string currentTier: (service && service.currentTier !== "--") ? service.currentTier : _localCurrentTier
  property string _localCurrentProfile: "--"
  readonly property string currentProfile: (service && service.currentProfile !== "--") ? service.currentProfile : _localCurrentProfile
  property string _localRecommendedTier: "--"
  readonly property string recommendedTier: (service && service.recommendedTier !== "--") ? service.recommendedTier : _localRecommendedTier
  property string _localRecommendedProfile: "--"
  readonly property string recommendedProfile: (service && service.recommendedProfile !== "--") ? service.recommendedProfile : _localRecommendedProfile
  property string _localCandidateTier: "--"
  readonly property string candidateTier: (service && service.candidateTier !== "--") ? service.candidateTier : _localCandidateTier
  property string _localCandidateProfile: "--"
  readonly property string candidateProfile: (service && service.candidateProfile !== "--") ? service.candidateProfile : _localCandidateProfile
  property real _localSmoothedDemand: 0.0
  readonly property real smoothedDemand: service ? service.smoothedDemand : _localSmoothedDemand
  property bool _localManualOverride: false
  readonly property bool manualOverride: service ? service.manualOverride : _localManualOverride
  property var _localReasons: []
  readonly property var reasons: (service && service.reasons && service.reasons.length > 0) ? service.reasons : _localReasons
  property bool applied: false
  property bool _localApplying: false
  readonly property bool applying: service ? service.applying : _localApplying
  property bool _localAutoApply: false
  readonly property bool autoApply: service ? service.autoApply : _localAutoApply

  // Settings persistence
  readonly property string settingsPath: Quickshell.env("DAEMON_FLOW_SETTINGS_PATH") || (Quickshell.env("HOME") + "/.config/omarchy/flow.json")
  property bool settingsReady: false

  function saveSettings() {
    if (service) {
      service.saveSettings();
      return;
    }
    if (!settingsReady) return;
    try {
      settingsFile.setText(JSON.stringify({
        schema: 1,
        autoApply: root._localAutoApply
      }, null, 2) + "\n");
    } catch (e) {
      console.warn("Failed to save flow settings:", e);
    }
  }

  function toggleAutoApply() {
    if (service) {
      service.toggleAutoApply();
      return;
    }
    _localAutoApply = !_localAutoApply;
    saveSettings();
    if (_localAutoApply && hasData) {
      var tDiff = recommendedTier && recommendedTier !== "--" && (currentTier.toLowerCase() !== recommendedTier.toLowerCase());
      var pDiff = recommendedProfile && recommendedProfile !== "--" && (currentProfile.toLowerCase() !== recommendedProfile.toLowerCase());
      if (tDiff || pDiff) {
        applyRecommendation();
      }
    }
  }

  FileView {
    id: settingsFile
    path: root.settingsPath
    printErrors: false
    atomicWrites: true
    onLoaded: {
      try {
        var raw = text();
        if (raw && raw.trim().length > 0) {
          var saved = JSON.parse(raw);
          if (saved && typeof saved.autoApply === "boolean") {
            root._localAutoApply = saved.autoApply;
          }
        }
      } catch (e) {
        console.warn("Failed to parse flow settings:", e);
      }
      root.settingsReady = true;
    }
    onLoadFailed: {
      root.settingsReady = true;
      root.saveSettings();
    }
  }

  function applyRecommendation() {
    if (service) {
      service.applyRecommendation();
      return;
    }
    if (applying || !hasData) return;
    var tierDiff = recommendedTier && recommendedTier !== "--" && (currentTier.toLowerCase() !== recommendedTier.toLowerCase());
    var profileDiff = recommendedProfile && recommendedProfile !== "--" && (currentProfile.toLowerCase() !== recommendedProfile.toLowerCase());
    if (!tierDiff && !profileDiff) return;

    _localApplying = true;
    if (tierDiff) {
      _localLastError = "Applying " + recommendedTier + "...";
      applyProcess.command = [Quickshell.env("HOME") + "/.local/bin/ryzen-power-ctl", "tier", recommendedTier.toLowerCase()];
      applyProcess.running = true;
    } else {
      _localLastError = "Applying profile " + recommendedProfile + "...";
      applyProfileProcess.command = [Quickshell.env("HOME") + "/.local/bin/ryzen-power-ctl", "set", recommendedProfile.toLowerCase()];
      applyProfileProcess.running = true;
    }
  }

  readonly property string scriptPath: decodeURIComponent(String(Qt.resolvedUrl("monitor.py")).replace(/^file:\/\//, ""))

  function resolvePopupAnchor() {
    popupAnchor = null;
    popupBar = null;
    var candidateBar = shell && shell.bar ? shell.bar : null;
    if (!candidateBar || candidateBar.barHidden || !candidateBar.moduleSlots || typeof candidateBar.slotWindow !== "function") return;
    var screenName = typeof candidateBar.focusedScreenName === "function" ? candidateBar.focusedScreenName() : "";
    var fallback = null;
    for (var i = 0; i < candidateBar.moduleSlots.length; i++) {
      var slot = candidateBar.moduleSlots[i];
      var item = slot && slot.activeItem;
      if (!item || item.visible === false || item.width <= 0) continue;
      var window = candidateBar.slotWindow(slot);
      if (!window || !window.screen) continue;
      if (!fallback) fallback = item;
      if (screenName && window.screen.name === screenName) {
        popupAnchor = item;
        popupBar = candidateBar;
        return;
      }
    }
    if (fallback && !screenName) { popupAnchor = fallback; popupBar = candidateBar; }
  }

  function open(payloadJson) {
    resolvePopupAnchor();
    isOpen = true;
    if (service) service.triggerSample();
    else startSampling();
    Qt.callLater(function() { keyCatcher.forceActiveFocus(); });
  }

  function close() {
    isOpen = false;
    stopSampling();
  }

  function requestClose() {
    if (shell) shell.hide("daemon0.flow");
    else close();
  }

  function startSampling() {
    if (service && service.hasData) return;
    sampleCount = 0;
    _localStatusMessage = "Sampling 1 of " + maxSamples + " (1s interval)...";
    _localLastError = "";
    sampling = true;
    monitorProcess.running = false;
    monitorProcess.running = true;
  }

  function stopSampling() {
    sampling = false;
    monitorProcess.running = false;
  }

  function refresh() {
    if (!isOpen) return;
    if (service) {
      service.triggerSample();
    } else {
      startSampling();
    }
  }

  function parseNdjson(line) {
    var raw = String(line || "").trim();
    if (!raw) return;
    try {
      var data = JSON.parse(raw);
      var s = data.sample;
      var d = data.decision;
      if (!s || !d) return;

      if (s.cpu !== undefined && s.cpu !== null) _localCpu = Number(s.cpu);
      if (s.busiest_core !== undefined && s.busiest_core !== null) _localBusiestCore = Number(s.busiest_core);
      if (s.gpu !== undefined && s.gpu !== null) _localGpu = Number(s.gpu);
      if (s.temperature !== undefined && s.temperature !== null) _localTemperature = Number(s.temperature);
      if (s.battery !== undefined && s.battery !== null) _localBattery = Number(s.battery);
      if (s.memory_pressure !== undefined && s.memory_pressure !== null) _localMemoryPressure = Number(s.memory_pressure);
      if (s.on_ac !== undefined) _localOnAc = s.on_ac === true;

      if (s.tier) _localCurrentTier = String(s.tier);
      if (s.profile) _localCurrentProfile = String(s.profile);

      if (d.recommended) {
        if (d.recommended.tier) _localRecommendedTier = String(d.recommended.tier);
        if (d.recommended.profile) _localRecommendedProfile = String(d.recommended.profile);
      }
      if (d.candidate) {
        if (d.candidate.tier) _localCandidateTier = String(d.candidate.tier);
        if (d.candidate.profile) _localCandidateProfile = String(d.candidate.profile);
      }
      if (d.smoothed_demand !== undefined && d.smoothed_demand !== null) _localSmoothedDemand = Number(d.smoothed_demand);
      if (d.manual_override !== undefined) _localManualOverride = d.manual_override === true;
      if (Array.isArray(d.reasons)) _localReasons = d.reasons;
      if (d.applied !== undefined) applied = d.applied === true;

      sampleCount++;
      _localHasData = true;
      if (sampleCount >= maxSamples) {
        _localStatusMessage = "Sampling complete (" + maxSamples + " samples)";
      } else {
        _localStatusMessage = "Sampling " + (sampleCount + 1) + " of " + maxSamples + " (1s interval)...";
      }
      _localLastError = "";

      if (root.autoApply && !root.applying) {
        var tDiff = root.recommendedTier && root.recommendedTier !== "--" && (root.currentTier.toLowerCase() !== root.recommendedTier.toLowerCase());
        var pDiff = root.recommendedProfile && root.recommendedProfile !== "--" && (root.currentProfile.toLowerCase() !== root.recommendedProfile.toLowerCase());
        if (tDiff || pDiff) {
          root.applyRecommendation();
        }
      }
    } catch (e) {
      _localLastError = "Telemetry parse error";
    }
  }

  onIsOpenChanged: {
    if (isOpen) {
      if (service) service.triggerSample();
      else startSampling();
    } else {
      stopSampling();
    }
  }

  Process {
    id: monitorProcess
    command: ["/usr/bin/python3", root.scriptPath, "--samples", String(root.maxSamples), "--interval", "1"]
    running: false
    stdout: SplitParser {
      onRead: function(line) {
        root.parseNdjson(line);
      }
    }
    onExited: function(exitCode, exitStatus) {
      root.sampling = false;
      if (exitCode !== 0 && root.isOpen) {
        root.statusMessage = "Monitor exited with code " + exitCode;
        root.lastError = "Sampling stopped";
      } else if (root.hasData) {
        root.statusMessage = "Sampling complete (" + root.maxSamples + " samples)";
      }
    }
  }

  Process {
    id: applyProcess
    running: false
    onExited: function(exitCode, exitStatus) {
      if (exitCode !== 0) {
        root._localApplying = false;
        root._localLastError = "Failed to set power tier";
      } else if (root.recommendedProfile && root.recommendedProfile !== "--" && root.recommendedProfile.toLowerCase() !== root.currentProfile.toLowerCase()) {
        applyProfileProcess.command = [Quickshell.env("HOME") + "/.local/bin/ryzen-power-ctl", "set", root.recommendedProfile.toLowerCase()];
        applyProfileProcess.running = true;
      } else {
        root._localApplying = false;
        root._localLastError = "Applied " + root.recommendedTier;
        root.refresh();
      }
    }
  }

  Process {
    id: applyProfileProcess
    running: false
    onExited: function(exitCode, exitStatus) {
      root._localApplying = false;
      if (exitCode !== 0) {
        root._localLastError = "Tier applied; profile set failed";
      } else {
        root._localLastError = "Applied " + root.recommendedTier + " & " + root.recommendedProfile;
      }
      root.refresh();
    }
  }

  MusicKeyboardPanel {
    id: popup
    anchorItem: root.popupAnchor
    bar: root.popupBar
    centerOnBar: true
    owner: QtObject { function close() { root.requestClose(); } }
    open: root.isOpen
    focusTarget: keyCatcher
    contentWidth: fittedContentWidth(Style.space(640))
    contentHeight: cappedContentHeight(Style.space(440))

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true
      Keys.onEscapePressed: root.requestClose()
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_R || (event.modifiers & Qt.ControlModifier && event.key === Qt.Key_R)) {
          root.refresh();
          event.accepted = true;
        } else if (event.key === Qt.Key_A && !root.applying) {
          root.applyRecommendation();
          event.accepted = true;
        } else if (event.key === Qt.Key_U || (event.modifiers & Qt.ControlModifier && event.key === Qt.Key_U)) {
          root.toggleAutoApply();
          event.accepted = true;
        } else if (event.key === Qt.Key_Escape) {
          root.requestClose();
          event.accepted = true;
        }
      }

      ColumnLayout {
        anchors.fill: parent
        spacing: Style.space(10)

        // Header: Title, Mode badge, Refresh & Close buttons
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)

          FlowText {
            text: "DAEMON Flow"
            font.family: Style.font.family
            font.pixelSize: Style.font.title
            font.bold: true
          }

          Rectangle {
            height: Style.space(20)
            radius: Style.cornerRadius
            color: Style.normalFillFor(Palette.Color.surface)
            border.color: Style.normalBorderColor
            border.width: 1
            implicitWidth: badgeText.implicitWidth + Style.space(12)

            FlowText {
              id: badgeText
              anchors.centerIn: parent
              text: root.autoApply ? "AUTOMATIC" : "ADVISORY"
              font.pixelSize: Style.font.caption
              opacity: 0.75
            }
          }

          Item { Layout.fillWidth: true }

          Ui.Button {
            text: "Refresh (R)"
            focusable: true
            onClicked: root.refresh()
          }

          Ui.Button {
            text: "Close (Esc)"
            focusable: true
            onClicked: root.requestClose()
          }
        }

        // Status row
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)

          FlowText {
            text: root.statusMessage
            font.pixelSize: Style.font.caption
            opacity: 0.8
          }

          Item { Layout.fillWidth: true }

          FlowText {
            text: root.onAc ? "⚡ AC Connected" : ("🔋 Battery: " + root.battery.toFixed(0) + "%")
            font.pixelSize: Style.font.caption
            font.bold: true
            opacity: 0.9
          }
        }

        // Metrics Grid (4 Stat Cards)
        GridLayout {
          Layout.fillWidth: true
          columns: 4
          rowSpacing: Style.space(8)
          columnSpacing: Style.space(8)

          // CPU Card
          Rectangle {
            Layout.fillWidth: true
            Layout.minimumHeight: Style.space(64)
            radius: Style.cornerRadius
            color: Style.normalFillFor(Palette.Color.surface)
            border.color: Style.normalBorderColor
            border.width: 1

            ColumnLayout {
              anchors.fill: parent
              anchors.margins: Style.space(8)
              spacing: Style.space(2)
              FlowText { text: "CPU Load"; font.pixelSize: Style.font.caption; opacity: 0.6 }
              FlowText { text: root.cpu.toFixed(1) + "%"; font.pixelSize: Style.font.title; font.bold: true }
              FlowText { text: "Peak Core: " + root.busiestCore.toFixed(1) + "%"; font.pixelSize: Style.font.caption; opacity: 0.5 }
            }
          }

          // GPU Card
          Rectangle {
            Layout.fillWidth: true
            Layout.minimumHeight: Style.space(64)
            radius: Style.cornerRadius
            color: Style.normalFillFor(Palette.Color.surface)
            border.color: Style.normalBorderColor
            border.width: 1

            ColumnLayout {
              anchors.fill: parent
              anchors.margins: Style.space(8)
              spacing: Style.space(2)
              FlowText { text: "GPU Busy"; font.pixelSize: Style.font.caption; opacity: 0.6 }
              FlowText { text: root.gpu.toFixed(1) + "%"; font.pixelSize: Style.font.title; font.bold: true }
              FlowText { text: "drm / amdgpu"; font.pixelSize: Style.font.caption; opacity: 0.5 }
            }
          }

          // Temperature Card
          Rectangle {
            Layout.fillWidth: true
            Layout.minimumHeight: Style.space(64)
            radius: Style.cornerRadius
            color: Style.normalFillFor(Palette.Color.surface)
            border.color: Style.normalBorderColor
            border.width: 1

            ColumnLayout {
              anchors.fill: parent
              anchors.margins: Style.space(8)
              spacing: Style.space(2)
              FlowText { text: "Temperature"; font.pixelSize: Style.font.caption; opacity: 0.6 }
              FlowText { text: root.temperature.toFixed(0) + "°C"; font.pixelSize: Style.font.title; font.bold: true }
              FlowText { text: "hwmon / k10temp"; font.pixelSize: Style.font.caption; opacity: 0.5 }
            }
          }

          // Demand EMA Card
          Rectangle {
            Layout.fillWidth: true
            Layout.minimumHeight: Style.space(64)
            radius: Style.cornerRadius
            color: Style.normalFillFor(Palette.Color.surface)
            border.color: Style.normalBorderColor
            border.width: 1

            ColumnLayout {
              anchors.fill: parent
              anchors.margins: Style.space(8)
              spacing: Style.space(2)
              FlowText { text: "Demand EMA"; font.pixelSize: Style.font.caption; opacity: 0.6 }
              FlowText { text: root.smoothedDemand.toFixed(1) + "%"; font.pixelSize: Style.font.title; font.bold: true }
              FlowText { text: "PSI Mem: " + root.memoryPressure.toFixed(2); font.pixelSize: Style.font.caption; opacity: 0.5 }
            }
          }
        }

        // Policy & Recommendation Card
        Rectangle {
          Layout.fillWidth: true
          Layout.fillHeight: true
          radius: Style.cornerRadius
          color: Style.normalFillFor(Palette.Color.surface)
          border.color: Style.normalBorderColor
          border.width: 1
          clip: true

          ColumnLayout {
            anchors.fill: parent
            anchors.margins: Style.space(12)
            spacing: Style.space(8)

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(16)

              ColumnLayout {
                spacing: Style.space(2)
                FlowText { text: "Current Active Tier & Profile"; font.pixelSize: Style.font.caption; opacity: 0.6 }
                FlowText {
                  text: root.currentTier.toUpperCase() + "  ·  " + root.currentProfile
                  font.pixelSize: Style.font.body
                  font.bold: true
                }
              }

              Item { Layout.fillWidth: true }

              ColumnLayout {
                spacing: Style.space(2)
                Layout.alignment: Qt.AlignRight
                FlowText {
                  text: "Policy Recommendation"
                  font.pixelSize: Style.font.caption
                  opacity: 0.6
                  horizontalAlignment: Text.AlignRight
                  Layout.alignment: Qt.AlignRight
                }
                RowLayout {
                  spacing: Style.space(8)
                  Layout.alignment: Qt.AlignRight
                  FlowText {
                    text: root.hasData ? (root.recommendedTier.toUpperCase() + "  ·  " + root.recommendedProfile) : "Evaluating..."
                    font.pixelSize: Style.font.body
                    font.bold: true
                    color: Palette.Color.accent
                    horizontalAlignment: Text.AlignRight
                  }
                  Ui.Button {
                    text: !root.hasData ? "Sampling..." : ((root.currentTier.toLowerCase() === root.recommendedTier.toLowerCase() && root.currentProfile.toLowerCase() === root.recommendedProfile.toLowerCase()) ? "In Sync" : (root.applying ? "Applying..." : "Apply (A)"))
                    enabled: !root.autoApply && root.hasData && !(root.currentTier.toLowerCase() === root.recommendedTier.toLowerCase() && root.currentProfile.toLowerCase() === root.recommendedProfile.toLowerCase()) && !root.applying
                    focusable: true
                    onClicked: root.applyRecommendation()
                  }
                }
              }
            }

            Rectangle {
              Layout.fillWidth: true
              height: 1
              color: Style.normalBorderColor
              opacity: 0.4
            }

            // Reasons & Operating Status
            ColumnLayout {
              Layout.fillWidth: true
              spacing: Style.space(4)

              FlowText {
                text: "Recommendation Reasons: " + (root.reasons.length > 0 ? root.reasons.join(", ") : "Evaluating telemetry...")
                font.pixelSize: Style.font.caption
                wrapMode: Text.Wrap
                Layout.fillWidth: true
                opacity: 0.85
              }

              FlowText {
                text: root.manualOverride ? "Manual/External Hold: Use Resume Auto to release" : "Autonomous Evaluation: No hold active"
                font.pixelSize: Style.font.caption
                wrapMode: Text.Wrap
                Layout.fillWidth: true
                opacity: 0.65
              }

              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(8)

                FlowText {
                  text: (root.currentTier.toLowerCase() === root.recommendedTier.toLowerCase() && root.currentProfile.toLowerCase() === root.recommendedProfile.toLowerCase())
                        ? "Hardware State: Synchronized with ryzen-power-daemon"
                        : (root.autoApply ? "Auto-Apply: Active (auto-synchronizing hardware tier)" : "Hardware Enforcement: Advisory (Click 'Apply' or toggle Auto-Apply)")
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.Wrap
                  Layout.fillWidth: true
                  opacity: 0.65
                }

                Ui.Button {
                  text: "Resume Auto"
                  visible: root.service && root.manualOverride
                  enabled: root.service && !root.applying
                  focusable: true
                  onClicked: root.service.resumeAutomatic()
                }
                Ui.Button {
                  text: root.autoApply ? "Auto: ON" : "Auto: OFF"
                  selected: root.autoApply
                  active: root.autoApply
                  focusable: true
                  onClicked: root.toggleAutoApply()
                }
              }
            }
          }
        }

        // Bottom Footer: Shortcut hints and error notices
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)

          FlowText {
            text: "A Apply · U Auto Toggle · R Refresh · Esc Close · Super+Ctrl+P Toggle"
            font.pixelSize: Style.font.caption
            opacity: 0.6
          }

          Item { Layout.fillWidth: true }

          FlowText {
            text: root.lastError
            visible: root.lastError !== ""
            color: Palette.Color.urgent
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }

  component FlowText: Text {
    textFormat: Text.PlainText
    color: Palette.Color.foreground
    font.family: Style.font.family
    font.pixelSize: Style.font.body
  }
}

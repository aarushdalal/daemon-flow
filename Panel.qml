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
  property int _localBusyCores: 0
  readonly property int busyCores: service ? service.busyCores : _localBusyCores
  property real _localGpu: 0.0
  readonly property real gpu: service ? service.gpu : _localGpu
  property real _localTemperature: 0.0
  readonly property real temperature: service ? service.temperature : _localTemperature
  property real _localBattery: 0.0
  readonly property real battery: service ? service.battery : _localBattery
  property real _localMemoryPressure: 0.0
  readonly property real memoryPressure: service ? service.memoryPressure : _localMemoryPressure
  property real _localIoPressure: 0.0
  readonly property real ioPressure: service ? service.ioPressure : _localIoPressure
  property string _localTaskClass: "idle"
  readonly property string taskClass: service ? service.taskClass : _localTaskClass
  property string _localTopComm: ""
  readonly property string topComm: service ? service.topComm : _localTopComm
  property int _localTargetWatts: 0
  readonly property int targetWatts: service ? service.targetWatts : _localTargetWatts
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
  property string _localFlowMode: "adaptive"
  readonly property string flowMode: service ? service.flowMode : _localFlowMode

  function tierCeilingText(tier) {
    var t = String(tier || "").toLowerCase();
    if (t === "extreme") return "92°C";
    if (t === "standard") return "85°C";
    if (t === "quiet") return "75°C";
    return "--";
  }

  function allocationLabel(profile) {
    var p = String(profile || "").toLowerCase();
    if (p === "performance") return "100%";
    if (p === "balanced") return "75%";
    if (p === "power-saver") return "50%";
    return p;
  }

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
        autoApply: root._localAutoApply,
        flowMode: root._localFlowMode
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

  function setFlowMode(mode) {
    if (service && typeof service.setFlowMode === "function") {
      service.setFlowMode(mode);
      return;
    }
    _localFlowMode = mode;
    saveSettings();
    refresh();
  }

  function setManualState(tier, profile) {
    if (service && typeof service.setManualState === "function") {
      service.setManualState(tier, profile);
      return;
    }
    if (applying) return;
    var wantedTier = tier || currentTier.toLowerCase();
    var wantedProfile = profile || currentProfile.toLowerCase();
    _localApplying = true;
    if (wantedTier && wantedTier !== currentTier.toLowerCase()) {
      applyProcess.command = [Quickshell.env("HOME") + "/.local/bin/ryzen-power-ctl", "-q", "tier", wantedTier];
      applyProcess.running = true;
    } else if (wantedProfile && wantedProfile !== currentProfile.toLowerCase()) {
      applyProfileProcess.command = [Quickshell.env("HOME") + "/.local/bin/ryzen-power-ctl", "-q", "set", wantedProfile];
      applyProfileProcess.running = true;
    } else {
      _localApplying = false;
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
          if (saved && (saved.flowMode === "adaptive" || saved.flowMode === "silent" || saved.flowMode === "focus")) {
            root._localFlowMode = saved.flowMode;
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
      applyProcess.command = [Quickshell.env("HOME") + "/.local/bin/ryzen-power-ctl", "-q", "tier", recommendedTier.toLowerCase()];
      applyProcess.running = true;
    } else {
      _localLastError = "Applying profile " + recommendedProfile + "...";
      applyProfileProcess.command = [Quickshell.env("HOME") + "/.local/bin/ryzen-power-ctl", "-q", "set", recommendedProfile.toLowerCase()];
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
    monitorProcess.command = ["/usr/bin/python3", root.scriptPath, "--samples", String(root.maxSamples), "--interval", "1", "--mode", root.flowMode];
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
      if (s.busy_cores !== undefined && s.busy_cores !== null) _localBusyCores = Number(s.busy_cores);
      if (s.gpu !== undefined && s.gpu !== null) _localGpu = Number(s.gpu);
      if (s.temperature !== undefined && s.temperature !== null) _localTemperature = Number(s.temperature);
      if (s.battery !== undefined && s.battery !== null) _localBattery = Number(s.battery);
      if (s.memory_pressure !== undefined && s.memory_pressure !== null) _localMemoryPressure = Number(s.memory_pressure);
      if (s.io_pressure !== undefined && s.io_pressure !== null) _localIoPressure = Number(s.io_pressure);
      if (s.task_class) _localTaskClass = String(s.task_class);
      if (s.top_comm !== undefined) _localTopComm = String(s.top_comm || "");
      if (s.target_watts !== undefined && s.target_watts !== null) _localTargetWatts = Number(s.target_watts);
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
    command: ["/usr/bin/python3", root.scriptPath, "--samples", String(root.maxSamples), "--interval", "1", "--mode", root.flowMode]
    running: false
    stdout: SplitParser {
      onRead: function(line) {
        root.parseNdjson(line);
      }
    }
    onExited: function(exitCode, exitStatus) {
      root.sampling = false;
      if (exitCode !== 0 && root.isOpen) {
        root._localStatusMessage = "Monitor exited with code " + exitCode;
        root._localLastError = "Sampling stopped";
      } else if (root.hasData) {
        root._localStatusMessage = "Sampling complete (" + root.maxSamples + " samples)";
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
        applyProfileProcess.command = [Quickshell.env("HOME") + "/.local/bin/ryzen-power-ctl", "-q", "set", root.recommendedProfile.toLowerCase()];
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
    contentWidth: fittedContentWidth(Style.space(700))
    contentHeight: fittedContentHeight(mainLayout.implicitHeight)

    Item {
      id: keyCatcher
      anchors.fill: parent
      clip: true
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
        id: mainLayout
        anchors.fill: parent
        spacing: Style.space(10)

        // Header: Title, Mode/Hold badge, Refresh & Close buttons
        RowLayout {
          Layout.fillWidth: true
          Layout.minimumWidth: 0
          spacing: Style.space(8)

          FlowText {
            text: "DAEMON Flow"
            font.family: Style.font.family
            font.pixelSize: Style.font.title
            font.bold: true
            elide: Text.ElideRight
          }

          Rectangle {
            height: Style.space(22)
            radius: Style.cornerRadius
            color: Style.normalFillFor(Palette.Color.surface)
            border.color: (root.autoApply && root.manualOverride) ? Palette.Color.urgent : Style.normalBorderColor
            border.width: 1
            implicitWidth: badgeText.implicitWidth + Style.space(14)

            FlowText {
              id: badgeText
              anchors.centerIn: parent
              text: !root.autoApply
                    ? "ADVISORY"
                    : (root.manualOverride
                       ? ("HELD (" + (root.onAc ? "AC" : "BAT") + ")")
                       : ("AUTO · " + root.flowMode.toUpperCase()))
              color: (root.autoApply && root.manualOverride) ? Palette.Color.urgent : Palette.Color.foreground
              font.pixelSize: Style.font.caption
              font.bold: root.autoApply && root.manualOverride
              opacity: (root.autoApply && root.manualOverride) ? 1.0 : 0.85
            }
          }

          Item { Layout.fillWidth: true; Layout.minimumWidth: 0 }

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
          Layout.minimumWidth: 0
          spacing: Style.space(8)

          FlowText {
            text: root.statusMessage
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            Layout.fillWidth: true
            Layout.minimumWidth: 0
            opacity: 0.8
          }

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
          Layout.minimumWidth: 0
          columns: 4
          rowSpacing: Style.space(8)
          columnSpacing: Style.space(8)

          // CPU Card
          Rectangle {
            Layout.fillWidth: true
            Layout.preferredWidth: 1
            Layout.minimumWidth: 0
            implicitHeight: Math.max(Style.space(66), cpuCol.implicitHeight + Style.space(16))
            Layout.minimumHeight: implicitHeight
            radius: Style.cornerRadius
            color: Style.normalFillFor(Palette.Color.surface)
            border.color: Style.normalBorderColor
            border.width: 1

            ColumnLayout {
              id: cpuCol
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.space(8)
              spacing: Style.space(2)
              FlowText { text: "CPU Load"; font.pixelSize: Style.font.caption; elide: Text.ElideRight; Layout.fillWidth: true; Layout.minimumWidth: 0; opacity: 0.6 }
              FlowText { text: root.cpu.toFixed(1) + "%"; font.pixelSize: Style.font.title; font.bold: true; elide: Text.ElideRight; Layout.fillWidth: true; Layout.minimumWidth: 0 }
              FlowText { text: "Peak: " + root.busiestCore.toFixed(0) + "% · " + root.busyCores + " busy"; font.pixelSize: Style.font.caption; elide: Text.ElideRight; Layout.fillWidth: true; Layout.minimumWidth: 0; opacity: 0.55 }
            }
          }

          // GPU & Task Card
          Rectangle {
            Layout.fillWidth: true
            Layout.preferredWidth: 1
            Layout.minimumWidth: 0
            implicitHeight: Math.max(Style.space(66), gpuCol.implicitHeight + Style.space(16))
            Layout.minimumHeight: implicitHeight
            radius: Style.cornerRadius
            color: Style.normalFillFor(Palette.Color.surface)
            border.color: Style.normalBorderColor
            border.width: 1

            ColumnLayout {
              id: gpuCol
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.space(8)
              spacing: Style.space(2)
              FlowText { text: "GPU · Task"; font.pixelSize: Style.font.caption; elide: Text.ElideRight; Layout.fillWidth: true; Layout.minimumWidth: 0; opacity: 0.6 }
              FlowText { text: root.gpu.toFixed(1) + "%"; font.pixelSize: Style.font.title; font.bold: true; elide: Text.ElideRight; Layout.fillWidth: true; Layout.minimumWidth: 0 }
              FlowText {
                text: root.taskClass + (root.topComm !== "" ? (" · " + root.topComm) : "")
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                opacity: 0.55
              }
            }
          }

          // Temperature Card
          Rectangle {
            Layout.fillWidth: true
            Layout.preferredWidth: 1
            Layout.minimumWidth: 0
            implicitHeight: Math.max(Style.space(66), tempCol.implicitHeight + Style.space(16))
            Layout.minimumHeight: implicitHeight
            radius: Style.cornerRadius
            color: Style.normalFillFor(Palette.Color.surface)
            border.color: Style.normalBorderColor
            border.width: 1

            ColumnLayout {
              id: tempCol
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.space(8)
              spacing: Style.space(2)
              FlowText { text: "Temperature"; font.pixelSize: Style.font.caption; elide: Text.ElideRight; Layout.fillWidth: true; Layout.minimumWidth: 0; opacity: 0.6 }
              FlowText { text: root.temperature.toFixed(0) + "°C"; font.pixelSize: Style.font.title; font.bold: true; elide: Text.ElideRight; Layout.fillWidth: true; Layout.minimumWidth: 0 }
              FlowText { text: "Cap: " + root.tierCeilingText(root.currentTier); font.pixelSize: Style.font.caption; elide: Text.ElideRight; Layout.fillWidth: true; Layout.minimumWidth: 0; opacity: 0.55 }
            }
          }

          // Power Envelope & EMA Card
          Rectangle {
            Layout.fillWidth: true
            Layout.preferredWidth: 1
            Layout.minimumWidth: 0
            implicitHeight: Math.max(Style.space(66), powerCol.implicitHeight + Style.space(16))
            Layout.minimumHeight: implicitHeight
            radius: Style.cornerRadius
            color: Style.normalFillFor(Palette.Color.surface)
            border.color: Style.normalBorderColor
            border.width: 1

            ColumnLayout {
              id: powerCol
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.space(8)
              spacing: Style.space(2)
              FlowText { text: "Power Target"; font.pixelSize: Style.font.caption; elide: Text.ElideRight; Layout.fillWidth: true; Layout.minimumWidth: 0; opacity: 0.6 }
              FlowText { text: (root.targetWatts > 0 ? (root.targetWatts + "W") : "--"); font.pixelSize: Style.font.title; font.bold: true; elide: Text.ElideRight; Layout.fillWidth: true; Layout.minimumWidth: 0 }
              FlowText { text: "EMA: " + root.smoothedDemand.toFixed(0) + "% · IO: " + root.ioPressure.toFixed(1); font.pixelSize: Style.font.caption; elide: Text.ElideRight; Layout.fillWidth: true; Layout.minimumWidth: 0; opacity: 0.55 }
            }
          }
        }

        // Policy, Modes & Manual Tier/Allocation Controls Card
        Rectangle {
          id: policyCard
          Layout.fillWidth: true
          Layout.minimumWidth: 0
          Layout.fillHeight: true
          implicitHeight: policyColumn.implicitHeight + Style.space(24)
          radius: Style.cornerRadius
          color: Style.normalFillFor(Palette.Color.surface)
          border.color: Style.normalBorderColor
          border.width: 1
          clip: true

          ColumnLayout {
            id: policyColumn
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Style.space(12)
            spacing: Style.space(8)

            RowLayout {
              Layout.fillWidth: true
              Layout.minimumWidth: 0
              spacing: Style.space(16)

              ColumnLayout {
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                spacing: Style.space(2)
                FlowText { text: "Current Active Tier & Allocation"; font.pixelSize: Style.font.caption; elide: Text.ElideRight; Layout.fillWidth: true; Layout.minimumWidth: 0; opacity: 0.6 }
                FlowText {
                  text: root.currentTier.toUpperCase() + "  ·  " + root.allocationLabel(root.currentProfile) + " (" + root.currentProfile + ")"
                  font.pixelSize: Style.font.body
                  font.bold: true
                  elide: Text.ElideRight
                  Layout.fillWidth: true
                  Layout.minimumWidth: 0
                }
              }

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
                    text: root.hasData ? (root.recommendedTier.toUpperCase() + "  ·  " + root.allocationLabel(root.recommendedProfile)) : "Evaluating..."
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
              opacity: 0.35
            }

            // Flow Mode Row
            RowLayout {
              Layout.fillWidth: true
              Layout.minimumWidth: 0
              spacing: Style.space(6)
              FlowText { text: "Flow Mode:"; font.pixelSize: Style.font.caption; opacity: 0.7; Layout.preferredWidth: Style.space(80) }
              Flow {
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                spacing: Style.space(6)
                Ui.Button {
                  text: "Adaptive"
                  selected: root.flowMode === "adaptive"
                  active: root.flowMode === "adaptive"
                  focusable: true
                  onClicked: root.setFlowMode("adaptive")
                }
                Ui.Button {
                  text: "Silent"
                  selected: root.flowMode === "silent"
                  active: root.flowMode === "silent"
                  focusable: true
                  onClicked: root.setFlowMode("silent")
                }
                Ui.Button {
                  text: "Focus"
                  selected: root.flowMode === "focus"
                  active: root.flowMode === "focus"
                  focusable: true
                  onClicked: root.setFlowMode("focus")
                }
              }
            }

            // Quick Tier & Allocation Override Row
            RowLayout {
              Layout.fillWidth: true
              Layout.minimumWidth: 0
              spacing: Style.space(6)
              FlowText { text: "Manual Hold:"; font.pixelSize: Style.font.caption; opacity: 0.7; Layout.preferredWidth: Style.space(80); Layout.alignment: Qt.AlignTop; topPadding: Style.space(6) }
              Flow {
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                spacing: Style.space(6)
                Ui.Button {
                  id: quietTierBtn
                  text: "Quiet"
                  selected: root.currentTier.toLowerCase() === "quiet"
                  active: root.currentTier.toLowerCase() === "quiet"
                  enabled: !root.applying
                  focusable: true
                  onClicked: root.setManualState("quiet", root.currentProfile.toLowerCase())
                }
                Ui.Button {
                  text: "Standard"
                  selected: root.currentTier.toLowerCase() === "standard"
                  active: root.currentTier.toLowerCase() === "standard"
                  enabled: !root.applying
                  focusable: true
                  onClicked: root.setManualState("standard", root.currentProfile.toLowerCase())
                }
                Ui.Button {
                  text: "Extreme"
                  selected: root.currentTier.toLowerCase() === "extreme"
                  active: root.currentTier.toLowerCase() === "extreme"
                  enabled: !root.applying
                  focusable: true
                  onClicked: root.setManualState("extreme", root.currentProfile.toLowerCase())
                }
                FlowText {
                  text: "·"
                  font.pixelSize: Style.font.caption
                  opacity: 0.5
                  height: quietTierBtn.height
                  verticalAlignment: Text.AlignVCenter
                }
                Ui.Button {
                  text: "50%"
                  selected: root.currentProfile.toLowerCase() === "power-saver"
                  active: root.currentProfile.toLowerCase() === "power-saver"
                  enabled: !root.applying
                  focusable: true
                  onClicked: root.setManualState(root.currentTier.toLowerCase(), "power-saver")
                }
                Ui.Button {
                  text: "75%"
                  selected: root.currentProfile.toLowerCase() === "balanced"
                  active: root.currentProfile.toLowerCase() === "balanced"
                  enabled: !root.applying
                  focusable: true
                  onClicked: root.setManualState(root.currentTier.toLowerCase(), "balanced")
                }
                Ui.Button {
                  text: "100%"
                  selected: root.currentProfile.toLowerCase() === "performance"
                  active: root.currentProfile.toLowerCase() === "performance"
                  enabled: !root.applying
                  focusable: true
                  onClicked: root.setManualState(root.currentTier.toLowerCase(), "performance")
                }
              }
            }

            Rectangle {
              Layout.fillWidth: true
              height: 1
              color: Style.normalBorderColor
              opacity: 0.35
            }

            // Reasons & Operating Status
            ColumnLayout {
              Layout.fillWidth: true
              Layout.minimumWidth: 0
              spacing: Style.space(4)

              FlowText {
                text: "Reasons: " + (root.reasons.length > 0 ? root.reasons.join(", ") : "Evaluating telemetry...")
                font.pixelSize: Style.font.caption
                wrapMode: Text.Wrap
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                opacity: 0.85
              }

              RowLayout {
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                spacing: Style.space(8)

                FlowText {
                  text: root.manualOverride
                        ? ("Held on " + (root.onAc ? "AC" : "Battery") + " — auto-releases on power change or Resume Auto")
                        : (root.autoApply ? "Autonomous task-aware control active" : "Advisory only (toggle Auto to enable)")
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.Wrap
                  Layout.fillWidth: true
                  Layout.minimumWidth: 0
                  opacity: 0.7
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

        // Dedicated wrapped notice row so long error text never overflows horizontally
        FlowText {
          visible: root.lastError !== ""
          text: root.lastError
          color: Palette.Color.urgent
          font.pixelSize: Style.font.caption
          wrapMode: Text.Wrap
          Layout.fillWidth: true
          Layout.minimumWidth: 0
        }

        // Bottom Footer: Shortcut hints
        FlowText {
          text: "A Apply · U Auto Toggle · R Refresh · Esc Close · Super+Ctrl+P Toggle"
          font.pixelSize: Style.font.caption
          opacity: 0.6
          elide: Text.ElideRight
          Layout.fillWidth: true
          Layout.minimumWidth: 0
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

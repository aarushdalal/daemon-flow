import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  property var shell: null
  readonly property string home: Quickshell.env("HOME")
  readonly property string settingsPath: Quickshell.env("DAEMON_FLOW_SETTINGS_PATH") || (home + "/.config/omarchy/flow.json")
  readonly property string scriptPath: decodeURIComponent(String(Qt.resolvedUrl("monitor.py")).replace(/^file:\/\//, ""))

  property bool autoApply: false
  property bool settingsReady: false
  property bool savedManualHold: false
  property var manualHoldOnAc: null
  property string flowMode: "adaptive"
  property bool monitorError: false

  // Hardware telemetry from monitor.py
  property real cpu: 0.0
  property real busiestCore: 0.0
  property int busyCores: 0
  property real gpu: 0.0
  property real temperature: 0.0
  property real battery: 0.0
  property real memoryPressure: 0.0
  property real cpuPressure: 0.0
  property real ioPressure: 0.0
  property real iowait: 0.0
  property real niceShare: 0.0
  property string taskClass: "idle"
  property string topComm: ""
  property int targetWatts: 0
  property bool onAc: false

  // Recommendation engine state from policy.py
  property string currentTier: "--"
  property string currentProfile: "--"
  property string recommendedTier: "--"
  property string recommendedProfile: "--"
  property string candidateTier: "--"
  property string candidateProfile: "--"
  property real smoothedDemand: 0.0
  property bool manualOverride: false
  property var reasons: []
  property bool hasData: false
  property bool applying: false
  property string lastError: ""
  property string statusMessage: "Idle"

  signal telemetryUpdated()

  function buildMonitorCommand() {
    var args = ["/usr/bin/python3", root.scriptPath, "--continuous", "--interval", "2", "--auto", "--mode", root.flowMode];
    if (root.savedManualHold) {
      if (root.manualHoldOnAc === true) args.push("--hold-on-ac", "ac");
      else if (root.manualHoldOnAc === false) args.push("--hold-on-ac", "bat");
      else args.push("--hold");
    }
    return args;
  }

  function validMode(m) {
    return m === "adaptive" || m === "silent" || m === "focus";
  }

  FileView {
    id: settingsFile
    path: root.settingsPath
    watchChanges: true
    onFileChanged: reload()
    printErrors: false
    atomicWrites: true
    onLoaded: {
      try {
        var raw = text();
        if (raw && raw.trim().length > 0) {
          var saved = JSON.parse(raw);
          if (saved) {
            var nextMode = root.validMode(saved.flowMode) ? saved.flowMode : root.flowMode;
            var modeChanged = root.flowMode !== nextMode;
            root.flowMode = nextMode;

            var nextHold = saved.manualHold === true;
            var nextHoldAc = (saved.manualHoldOnAc === true || saved.manualHoldOnAc === false) ? saved.manualHoldOnAc : null;
            var holdChanged = root.savedManualHold !== nextHold || root.manualHoldOnAc !== nextHoldAc;
            root.savedManualHold = nextHold;
            root.manualHoldOnAc = nextHoldAc;

            if (typeof saved.autoApply === "boolean") {
              var autoChanged = root.autoApply !== saved.autoApply;
              root.autoApply = saved.autoApply;
              if (autoChanged) {
                root.syncMonitorState();
              } else if ((modeChanged || holdChanged) && root.autoApply && monitorProcess.running) {
                monitorProcess.running = false;
                restartTimer.restart();
              }
            }
          }
        }
      } catch (e) {
        console.warn("[Flow Service] Failed to parse settings:", e);
      }
      root.settingsReady = true;
    }
    onLoadFailed: {
      root.settingsReady = true;
      root.saveSettings();
    }
  }

  function saveSettings() {
    if (!settingsReady) return;
    try {
      settingsFile.setText(JSON.stringify({
        schema: 1,
        autoApply: root.autoApply,
        manualHold: root.savedManualHold,
        manualHoldOnAc: root.manualHoldOnAc,
        flowMode: root.flowMode
      }, null, 2) + "\n");
    } catch (e) {
      console.warn("[Flow Service] Failed to save settings:", e);
    }
  }

  function toggleAutoApply() {
    if (root.applying) return;
    root.autoApply = !root.autoApply;
    if (root.autoApply) {
      root.savedManualHold = false;
      root.manualHoldOnAc = null;
      root.manualOverride = false;
    }
    root.saveSettings();
    root.syncMonitorState();
  }

  function setFlowMode(mode) {
    if (!validMode(mode) || root.flowMode === mode) return;
    root.flowMode = mode;
    root.savedManualHold = false;
    root.manualHoldOnAc = null;
    root.manualOverride = false;
    root.saveSettings();
    if (root.autoApply) {
      monitorProcess.running = false;
      restartTimer.restart();
    } else {
      root.triggerSample();
    }
  }

  function resumeAutomatic() {
    root.savedManualHold = false;
    root.manualHoldOnAc = null;
    root.manualOverride = false;
    root.autoApply = true;
    root.saveSettings();
    monitorProcess.running = false;
    restartTimer.restart();
  }

  function setManualState(tier, profile) {
    if (root.applying) return;
    var wantedTier = (tier && tier !== "--") ? tier.toLowerCase() : "";
    var wantedProfile = (profile && profile !== "--") ? profile.toLowerCase() : "";
    if (!wantedTier && !wantedProfile) return;

    root.applying = true;
    root._manualTargetTier = wantedTier || root.currentTier.toLowerCase();
    root._manualTargetProfile = wantedProfile || root.currentProfile.toLowerCase();

    if (root.autoApply) {
      root.savedManualHold = true;
      root.manualHoldOnAc = root.onAc;
      root.manualOverride = true;
      root.saveSettings();
      if (monitorProcess.running) {
        monitorProcess.running = false;
      }
    }

    if (wantedTier && wantedTier !== root.currentTier.toLowerCase()) {
      root.lastError = "Setting " + wantedTier + "...";
      manualTierProcess.command = [Quickshell.env("HOME") + "/.local/bin/ryzen-power-ctl", "-q", "tier", wantedTier];
      manualTierProcess.running = true;
    } else if (wantedProfile && wantedProfile !== root.currentProfile.toLowerCase()) {
      root.lastError = "Setting " + wantedProfile + "...";
      manualProfileProcess.command = [Quickshell.env("HOME") + "/.local/bin/ryzen-power-ctl", "-q", "set", wantedProfile];
      manualProfileProcess.running = true;
    } else {
      root.applying = false;
      root.lastError = "";
      if (root.autoApply) restartTimer.restart();
    }
  }

  property string _manualTargetTier: ""
  property string _manualTargetProfile: ""

  function syncMonitorState() {
    if (root.autoApply) {
      if (!monitorProcess.running) {
        monitorProcess.command = root.buildMonitorCommand();
        monitorProcess.running = true;
        root.statusMessage = "Continuous monitor (" + root.flowMode + ", 2s)";
      }
    } else {
      monitorProcess.running = false;
      root.statusMessage = "Monitor idle (Auto: OFF)";
    }
  }

  function triggerSample() {
    if (!monitorProcess.running) {
      singleSampleProcess.command = ["/usr/bin/python3", root.scriptPath, "--samples", "1", "--interval", "1", "--mode", root.flowMode];
      singleSampleProcess.running = false;
      singleSampleProcess.running = true;
    }
  }

  function checkAndApply() {
    // Automatic transitions belong solely to the long-lived Python engine.
  }

  function applyRecommendation() {
    if (root.autoApply || root.applying || !root.hasData) return;
    var tierDiff = root.recommendedTier && root.recommendedTier !== "--" && (root.currentTier.toLowerCase() !== root.recommendedTier.toLowerCase());
    var profileDiff = root.recommendedProfile && root.recommendedProfile !== "--" && (root.currentProfile.toLowerCase() !== root.recommendedProfile.toLowerCase());
    if (!tierDiff && !profileDiff) return;

    root.applying = true;
    if (tierDiff) {
      root.lastError = "Applying " + root.recommendedTier + "...";
      applyProcess.command = [Quickshell.env("HOME") + "/.local/bin/ryzen-power-ctl", "-q", "tier", root.recommendedTier.toLowerCase()];
      applyProcess.running = true;
    } else {
      root.lastError = "Applying profile " + root.recommendedProfile + "...";
      applyProfileProcess.command = [Quickshell.env("HOME") + "/.local/bin/ryzen-power-ctl", "-q", "set", root.recommendedProfile.toLowerCase()];
      applyProfileProcess.running = true;
    }
  }

  function notifyHold(isOnAc) {
    var src = isOnAc ? "AC" : "Battery";
    var cmd = [
      "omarchy-notification-send", "-g", "svg:power", "-u", "low", "-t", "3500",
      "DAEMON Flow: Manual Hold (" + src + ")",
      "Held at " + root.currentTier.toUpperCase() + " / " + root.currentProfile + " until power source changes or Resume Auto"
    ];
    holdNotifyProcess.command = cmd;
    holdNotifyProcess.running = true;
  }

  Process {
    id: holdNotifyProcess
    running: false
  }

  Process {
    id: monitorProcess
    command: root.buildMonitorCommand()
    running: false
    stdout: SplitParser {
      onRead: function(line) {
        root.parseNdjson(line);
      }
    }
    onExited: function(exitCode, exitStatus) {
      if (root.autoApply && !root.applying) {
        restartTimer.restart();
      }
    }
  }

  Process {
    id: singleSampleProcess
    command: ["/usr/bin/python3", root.scriptPath, "--samples", "1", "--interval", "1", "--mode", root.flowMode]
    running: false
    stdout: SplitParser {
      onRead: function(line) {
        root.parseNdjson(line);
      }
    }
  }

  Timer {
    id: restartTimer
    interval: 600
    repeat: false
    onTriggered: {
      if (root.autoApply && !root.applying && !monitorProcess.running) {
        monitorProcess.command = root.buildMonitorCommand();
        monitorProcess.running = true;
      }
    }
  }

  Process {
    id: applyProcess
    running: false
    onExited: function(exitCode, exitStatus) {
      if (exitCode !== 0) {
        root.applying = false;
        root.lastError = "Failed to set power tier";
      } else if (root.recommendedProfile && root.recommendedProfile !== "--" && root.recommendedProfile.toLowerCase() !== root.currentProfile.toLowerCase()) {
        applyProfileProcess.command = [Quickshell.env("HOME") + "/.local/bin/ryzen-power-ctl", "-q", "set", root.recommendedProfile.toLowerCase()];
        applyProfileProcess.running = true;
      } else {
        root.applying = false;
        root.lastError = "";
        root.triggerSample();
      }
    }
  }

  Process {
    id: applyProfileProcess
    running: false
    onExited: function(exitCode, exitStatus) {
      root.applying = false;
      if (exitCode !== 0) {
        root.lastError = "Profile set failed";
      } else {
        root.lastError = "";
      }
      root.triggerSample();
    }
  }

  Process {
    id: manualTierProcess
    running: false
    onExited: function(exitCode, exitStatus) {
      if (exitCode !== 0) {
        root.applying = false;
        root.lastError = "Failed to set tier";
        if (root.autoApply) restartTimer.restart();
      } else if (root._manualTargetProfile && root._manualTargetProfile !== root.currentProfile.toLowerCase()) {
        manualProfileProcess.command = [Quickshell.env("HOME") + "/.local/bin/ryzen-power-ctl", "-q", "set", root._manualTargetProfile];
        manualProfileProcess.running = true;
      } else {
        root.applying = false;
        root.lastError = "";
        root.currentTier = root._manualTargetTier;
        if (root.autoApply) restartTimer.restart();
        else root.triggerSample();
      }
    }
  }

  Process {
    id: manualProfileProcess
    running: false
    onExited: function(exitCode, exitStatus) {
      root.applying = false;
      if (exitCode !== 0) {
        root.lastError = "Failed to set allocation";
      } else {
        root.lastError = "";
        root.currentTier = root._manualTargetTier;
        root.currentProfile = root._manualTargetProfile;
      }
      if (root.autoApply) restartTimer.restart();
      else root.triggerSample();
    }
  }

  function parseNdjson(line) {
    var raw = String(line || "").trim();
    if (!raw) return;
    try {
      var data = JSON.parse(raw);
      if (data.error) {
        root.lastError = "Telemetry unavailable; automatic changes suspended";
        root.monitorError = true;
        return;
      }
      var s = data.sample;
      var d = data.decision;
      if (!s || !d) return;

      var wasManualOverride = root.manualOverride;
      var hadData = root.hasData;

      if (s.cpu !== undefined && s.cpu !== null) cpu = Number(s.cpu);
      if (s.busiest_core !== undefined && s.busiest_core !== null) busiestCore = Number(s.busiest_core);
      if (s.busy_cores !== undefined && s.busy_cores !== null) busyCores = Number(s.busy_cores);
      if (s.gpu !== undefined && s.gpu !== null) gpu = Number(s.gpu);
      if (s.temperature !== undefined && s.temperature !== null) temperature = Number(s.temperature);
      if (s.battery !== undefined && s.battery !== null) battery = Number(s.battery);
      if (s.memory_pressure !== undefined && s.memory_pressure !== null) memoryPressure = Number(s.memory_pressure);
      if (s.cpu_pressure !== undefined && s.cpu_pressure !== null) cpuPressure = Number(s.cpu_pressure);
      if (s.io_pressure !== undefined && s.io_pressure !== null) ioPressure = Number(s.io_pressure);
      if (s.iowait !== undefined && s.iowait !== null) iowait = Number(s.iowait);
      if (s.nice_share !== undefined && s.nice_share !== null) niceShare = Number(s.nice_share);
      if (s.task_class) taskClass = String(s.task_class);
      if (s.top_comm !== undefined) topComm = String(s.top_comm || "");
      if (s.target_watts !== undefined && s.target_watts !== null) targetWatts = Number(s.target_watts);
      if (s.on_ac !== undefined) onAc = s.on_ac === true;

      if (s.tier) currentTier = String(s.tier);
      if (s.profile) currentProfile = String(s.profile);

      if (d.verified_current) {
        currentTier = String(d.verified_current.tier);
        currentProfile = String(d.verified_current.profile);
      }
      if (d.target_watts !== undefined && d.target_watts !== null) {
        targetWatts = Number(d.target_watts);
      }
      if (d.recommended) {
        if (d.recommended.tier) recommendedTier = String(d.recommended.tier);
        if (d.recommended.profile) recommendedProfile = String(d.recommended.profile);
      }
      if (d.candidate) {
        if (d.candidate.tier) candidateTier = String(d.candidate.tier);
        if (d.candidate.profile) candidateProfile = String(d.candidate.profile);
      }
      if (d.smoothed_demand !== undefined && d.smoothed_demand !== null) smoothedDemand = Number(d.smoothed_demand);
      if (d.busy_cores !== undefined && d.busy_cores !== null) busyCores = Number(d.busy_cores);
      if (d.task_class) taskClass = String(d.task_class);
      if (d.manual_override !== undefined) manualOverride = d.manual_override === true;
      if (Array.isArray(d.reasons)) reasons = d.reasons;

      if (root.autoApply) {
        var nextHoldAc = (d.hold_on_ac === true || d.hold_on_ac === false) ? d.hold_on_ac : null;
        if (root.savedManualHold !== manualOverride || root.manualHoldOnAc !== nextHoldAc) {
          root.savedManualHold = manualOverride;
          root.manualHoldOnAc = manualOverride ? nextHoldAc : null;
          root.saveSettings();
        }
        if (hadData && !wasManualOverride && manualOverride) {
          root.notifyHold(root.onAc);
        }
      }

      if (d.apply_error) root.lastError = String(d.apply_error);
      else if (root.monitorError || d.applied) root.lastError = "";
      root.monitorError = false;
      hasData = true;
      if (!root.autoApply) {
        statusMessage = "Advisory sample (" + root.flowMode + "); Auto: OFF";
      } else if (manualOverride) {
        var srcLabel = (root.manualHoldOnAc === true || (root.manualHoldOnAc === null && root.onAc)) ? "AC" : "Battery";
        statusMessage = "Manual hold on " + srcLabel + " (auto-releases on power switch)";
      } else {
        statusMessage = "Auto " + root.flowMode + " control (2s samples)";
      }
      telemetryUpdated();

      if (root.autoApply && !root.applying) {
        root.checkAndApply();
      }
    } catch (e) {
      root.lastError = "Telemetry parse error";
    }
  }

  Component.onCompleted: {
    if (root.autoApply) {
      root.syncMonitorState();
    }
  }

  IpcHandler {
    target: "flow"
    function status(): string {
      return JSON.stringify({
        revision: "flow-demand-v3",
        autoApply: root.autoApply,
        flowMode: root.flowMode,
        hasData: root.hasData,
        manualOverride: root.manualOverride,
        manualHoldOnAc: root.manualHoldOnAc,
        onAc: root.onAc,
        currentTier: root.currentTier,
        currentProfile: root.currentProfile,
        targetWatts: root.targetWatts,
        recommendedTier: root.recommendedTier,
        recommendedProfile: root.recommendedProfile,
        cpu: root.cpu,
        busiestCore: root.busiestCore,
        busyCores: root.busyCores,
        gpu: root.gpu,
        temperature: root.temperature,
        taskClass: root.taskClass,
        topComm: root.topComm,
        reasons: root.reasons,
        lastError: root.lastError,
        status: root.statusMessage
      });
    }
    function resume(): string { root.resumeAutomatic(); return "ok"; }
    function pause(): string {
      if (root.autoApply) root.toggleAutoApply();
      return root.autoApply ? "busy" : "ok";
    }
    function mode(nextMode: string): string {
      if (!root.validMode(nextMode)) return "invalid";
      root.setFlowMode(nextMode);
      return "ok";
    }
    function set(tier: string, profile: string): string {
      root.setManualState(tier, profile);
      return "ok";
    }
  }
}

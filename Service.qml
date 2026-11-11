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
  property bool monitorError: false

  // Hardware telemetry from monitor.py
  property real cpu: 0.0
  property real busiestCore: 0.0
  property real gpu: 0.0
  property real temperature: 0.0
  property real battery: 0.0
  property real memoryPressure: 0.0
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
          if (saved && typeof saved.autoApply === "boolean") {
            root.savedManualHold = saved.manualHold === true;
            var changed = root.autoApply !== saved.autoApply;
            root.autoApply = saved.autoApply;
            if (changed) {
              root.syncMonitorState();
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
        manualHold: root.savedManualHold
      }, null, 2) + "\n");
    } catch (e) {
      console.warn("[Flow Service] Failed to save settings:", e);
    }
  }

  function toggleAutoApply() {
    if (root.applying) return;
    root.autoApply = !root.autoApply;
    if (root.autoApply) root.savedManualHold = false;
    root.saveSettings();
    root.syncMonitorState();
    if (root.autoApply && root.hasData) {
      root.checkAndApply();
    }
  }

  function resumeAutomatic() {
    root.savedManualHold = false;
    root.manualOverride = false;
    root.autoApply = true;
    root.saveSettings();
    monitorProcess.running = false;
    restartTimer.restart();
  }

  function syncMonitorState() {
    if (root.autoApply) {
      if (!monitorProcess.running) {
        monitorProcess.running = true;
        root.statusMessage = "Continuous background monitor running (2s interval)";
      }
    } else {
      monitorProcess.running = false;
      root.statusMessage = "Monitor idle (Auto: OFF)";
    }
  }

  function triggerSample() {
    if (!monitorProcess.running) {
      singleSampleProcess.running = false;
      singleSampleProcess.running = true;
    }
  }

  function checkAndApply() {
    // Automatic transitions belong solely to the long-lived Python engine.
    // QML must not race its actuator or mislabel its own transitions as manual.
  }

  function applyRecommendation() {
    if (root.autoApply || root.applying || !root.hasData) return;
    var tierDiff = root.recommendedTier && root.recommendedTier !== "--" && (root.currentTier.toLowerCase() !== root.recommendedTier.toLowerCase());
    var profileDiff = root.recommendedProfile && root.recommendedProfile !== "--" && (root.currentProfile.toLowerCase() !== root.recommendedProfile.toLowerCase());
    if (!tierDiff && !profileDiff) return;

    root.applying = true;
    if (tierDiff) {
      root.lastError = "Applying " + root.recommendedTier + "...";
      applyProcess.command = [Quickshell.env("HOME") + "/.local/bin/ryzen-power-ctl", "tier", root.recommendedTier.toLowerCase()];
      applyProcess.running = true;
    } else {
      root.lastError = "Applying profile " + root.recommendedProfile + "...";
      applyProfileProcess.command = [Quickshell.env("HOME") + "/.local/bin/ryzen-power-ctl", "set", root.recommendedProfile.toLowerCase()];
      applyProfileProcess.running = true;
    }
  }

  Process {
    id: monitorProcess
    command: ["/usr/bin/python3", root.scriptPath, "--continuous", "--interval", "2", "--auto"].concat(root.savedManualHold ? ["--hold"] : [])
    running: false
    stdout: SplitParser {
      onRead: function(line) {
        root.parseNdjson(line);
      }
    }
    onExited: function(exitCode, exitStatus) {
      if (root.autoApply) {
        restartTimer.restart();
      }
    }
  }

  Process {
    id: singleSampleProcess
    command: ["/usr/bin/python3", root.scriptPath, "--samples", "1", "--interval", "1"]
    running: false
    stdout: SplitParser {
      onRead: function(line) {
        root.parseNdjson(line);
      }
    }
  }

  Timer {
    id: restartTimer
    interval: 2000
    repeat: false
    onTriggered: {
      if (root.autoApply && !monitorProcess.running) {
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
        applyProfileProcess.command = [Quickshell.env("HOME") + "/.local/bin/ryzen-power-ctl", "set", root.recommendedProfile.toLowerCase()];
        applyProfileProcess.running = true;
      } else {
        root.applying = false;
        root.lastError = "Applied " + root.recommendedTier;
      }
    }
  }

  Process {
    id: applyProfileProcess
    running: false
    onExited: function(exitCode, exitStatus) {
      root.applying = false;
      if (exitCode !== 0) {
        root.lastError = "Tier applied; profile set failed";
      } else {
        root.lastError = "Applied " + root.recommendedTier + " & " + root.recommendedProfile;
      }
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

      if (s.cpu !== undefined && s.cpu !== null) cpu = Number(s.cpu);
      if (s.busiest_core !== undefined && s.busiest_core !== null) busiestCore = Number(s.busiest_core);
      if (s.gpu !== undefined && s.gpu !== null) gpu = Number(s.gpu);
      if (s.temperature !== undefined && s.temperature !== null) temperature = Number(s.temperature);
      if (s.battery !== undefined && s.battery !== null) battery = Number(s.battery);
      if (s.memory_pressure !== undefined && s.memory_pressure !== null) memoryPressure = Number(s.memory_pressure);
      if (s.on_ac !== undefined) onAc = s.on_ac === true;

      if (s.tier) currentTier = String(s.tier);
      if (s.profile) currentProfile = String(s.profile);

      if (d.verified_current) {
        currentTier = String(d.verified_current.tier);
        currentProfile = String(d.verified_current.profile);
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
      if (d.manual_override !== undefined) manualOverride = d.manual_override === true;
      if (Array.isArray(d.reasons)) reasons = d.reasons;

      if (root.savedManualHold !== manualOverride && root.autoApply) {
        root.savedManualHold = manualOverride;
        root.saveSettings();
      }
      if (d.apply_error) root.lastError = String(d.apply_error);
      else if (root.monitorError || d.applied) root.lastError = "";
      root.monitorError = false;
      hasData = true;
      statusMessage = !root.autoApply ? "Advisory sample; Auto: OFF" : (manualOverride ? "Manual hold; use Resume Auto to release" : "Automatic demand control (2s samples)");
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
      return JSON.stringify({revision:"flow-demand-v2", autoApply:root.autoApply,
        hasData:root.hasData, manualOverride:root.manualOverride,
        currentTier:root.currentTier, currentProfile:root.currentProfile,
        recommendedTier:root.recommendedTier, recommendedProfile:root.recommendedProfile,
        cpu:root.cpu, busiestCore:root.busiestCore, temperature:root.temperature,
        reasons:root.reasons, lastError:root.lastError, status:root.statusMessage});
    }
    function resume(): string { root.resumeAutomatic(); return "ok"; }
    function pause(): string {
      if (root.autoApply) root.toggleAutoApply();
      return root.autoApply ? "busy" : "ok";
    }
  }
}

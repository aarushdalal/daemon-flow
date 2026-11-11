#!/usr/bin/env python3
"""Actual offscreen QML service with a scripted telemetry child, no hardware setters/UI."""
from pathlib import Path
import json
import os
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
QML = '''import Quickshell
import Quickshell.Io
import QtQuick
import "Flow" as Flow
Scope {
 id: host
 property int stage: 0
 property int ticks: 0
 property int updates: 0
 Flow.Service { id: service }
 Connections { target: service; function onTelemetryUpdated() { host.updates++; } }
 Process {
  id: externalSettings
  command: ["/usr/bin/python3", "-c", "import sys,json;open(sys.argv[1],'w').write(json.dumps({'schema':1,'autoApply':False}))", service.settingsPath]
 }
 Timer {
  interval:50; running:true; repeat:true
  onTriggered: {
   if (++host.ticks > 160) {
    console.log("FLOW_PROBE " + JSON.stringify({ok:false,stage:host.stage,updates:host.updates})); Qt.quit(); return;
   }
   if (host.stage === 0 && service.manualOverride && service.savedManualHold) {
    service.resumeAutomatic(); host.stage=1;
   } else if (host.stage === 1 && host.updates >= 3 && !service.manualOverride && !service.savedManualHold) {
    externalSettings.running=true; host.stage=2;
   } else if (host.stage === 2 && !service.autoApply) {
    console.log("FLOW_PROBE " + JSON.stringify({ok:true,manualHoldPersisted:true,resume:true,fileWatch:true,visibleWindows:false,hardwareApplied:false})); Qt.quit();
   }
  }
 }
}'''
with tempfile.TemporaryDirectory(prefix='flow-native-probe-') as name:
    folder = Path(name)
    (folder / 'Flow').mkdir()
    shutil.copy2(ROOT / 'Service.qml', folder / 'Flow/Service.qml')
    (folder / 'shell.qml').write_text(QML)
    settings = folder / 'settings.json'
    settings.write_text(json.dumps({'schema':1, 'autoApply':True, 'manualHold':False}))
    # A local fixture produces decisions; the test never runs control.py.
    fixture = '''import json,time
from pathlib import Path
f=Path(__file__).with_name('runs.json')
n=json.loads(f.read_text())+1 if f.exists() else 1
f.write_text(json.dumps(n))
sample={'cpu':30,'busiest_core':90,'temperature':55,'on_ac':True,'tier':'standard','profile':'balanced'}
decision={'recommended':{'tier':'standard','profile':'balanced'},'manual_override':False,'reasons':['fixture']}
print(json.dumps({'sample':sample,'decision':decision}),flush=True)
if n==1:
 time.sleep(.1)
 decision['manual_override']=True
 print(json.dumps({'sample':sample,'decision':decision}),flush=True)
time.sleep(20)
'''
    (folder / 'Flow/monitor.py').write_text(fixture)
    env = os.environ.copy()
    env.update(QT_QPA_PLATFORM='offscreen', DAEMON_FLOW_SETTINGS_PATH=str(settings))
    result = subprocess.run(['qs','-p',str(folder / 'shell.qml')], env=env, text=True, capture_output=True, timeout=12)
    lines = [line.split('FLOW_PROBE ',1)[1] for line in (result.stdout+result.stderr).splitlines() if 'FLOW_PROBE ' in line]
    if result.returncode or len(lines) != 1:
        raise SystemExit('Native service load/probe failed: ' + (result.stdout+result.stderr)[-1600:])
    summary = json.loads(lines[0])
    if not summary.get('ok'):
        raise SystemExit('Native service state-machine failed: ' + json.dumps(summary))
    print(json.dumps(summary,indent=2))

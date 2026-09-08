"""Check rendered cloud-init YAML and extracted JavaScript without executing setup."""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import yaml
ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'scripts/host/configure-host.ps1').read_text()
def literal(variable):
    return re.search(r'\$' + variable + r"\s*=\s*@'\n(.*?)\n'@", source, re.S).group(1)
node = literal('nodeJsRunCmdYaml')
nginx = literal('nginxRunCmdYaml')
network_prepare = literal('networkPrepare')
network = literal('networkConfig').replace('__MAC__', '00:15:5d:00:00:0c')
assert yaml.safe_load(network)['ethernets']['labnic']['dhcp4'] is True
cases = []
for extra in [node, nginx]:
    for password in ['Special:<>&"\'${1} #[]{}\\`Password42', 'Ordinary-Password234', 'Ab12__USER____RUNYAML____PKGYAML____PASSWORD__!']:
        cases.append({'Template': literal('userData'), 'User': 'labadmin', 'Password': password,
                      'Packages': '  - curl\n  - walinuxagent', 'Commands': network_prepare + '\n' + extra})
rendered_cases = subprocess.run(['pwsh', '-NoProfile', '-File', str(ROOT / 'tests/Render-CloudInit.ps1')],
                               input=json.dumps(cases), text=True, capture_output=True, check=True)
rendered_values = json.loads(rendered_cases.stdout)
assert len(rendered_values) == len(cases)
for case, rendered in zip(cases, rendered_values):
    data = yaml.safe_load(rendered)
    assert data['password'] == case['Password']
    assert data['users'][0]['plain_text_passwd'] == case['Password']
    assert all(isinstance(cmd, str) for cmd in data['runcmd'])
    assert any('netplan generate' in cmd for cmd in data['runcmd'])
    for cmd in data['runcmd']:
        checked = subprocess.run(['bash','-n'], input=cmd, text=True, capture_output=True)
        assert checked.returncode == 0, checked.stderr
server = re.search(r"cat > /opt/contoso-app/server.js << 'SERVERJS'\n(.*?)\n    SERVERJS", node, re.S).group(1)
server = '\n'.join(line[4:] if line.startswith('    ') else line for line in server.splitlines())
package = re.search(r"cat > /opt/contoso-app/package.json << 'PKGJSON'\n(.*?)\n    PKGJSON", node, re.S).group(1)
assert json.loads(package)['dependencies']['express'] == '5.2.1'
with tempfile.TemporaryDirectory() as tmp:
    path = Path(tmp) / 'server.js'
    path.write_text(server)
    subprocess.run(['node', '--check', str(path)], check=True)
assert '${JSON.stringify' in server and '`${PORT}' not in server  # template interpolation syntax must be preserved
# Execute the real Linux smoke-check scripts with local stub executables.
# A failed curl that has already printed matching content must not produce PASS.
checks_source = (ROOT / 'scripts/Test-MigratedWorkloads.ps1').read_text()
with tempfile.TemporaryDirectory() as tmp:
    stub_dir = Path(tmp)
    for name, body in {
        'systemctl': '#!/bin/sh\nexit 0\n',
        'curl': '#!/bin/sh\nprintf "%s\\n" "$CES_TEST_HTTP_BODY"\nexit "$CES_TEST_HTTP_EXIT"\n',
    }.items():
        path = stub_dir / name
        path.write_text(body)
        path.chmod(0o755)
    environment = dict(os.environ, PATH=str(stub_dir) + os.pathsep + os.environ['PATH'])
    for variable, success_body, wrong_body in [
        ('linuxWebCheck', 'TD SYNNEX', 'Welcome to nginx'),
        ('linuxAppCheck', '{"status":"healthy","server":"OnPrem-Linux-App"}', '{"status":"healthy","server":"wrong-app"}'),
    ]:
        script = re.search(r'\$' + variable + r"\s*=\s*@'\n(.*?)\n'@", checks_source, re.S).group(1)
        for exit_code, body, should_pass in [('0', success_body, True), ('7', success_body, False), ('0', wrong_body, False)]:
            result = subprocess.run(['sh'], input=script, text=True, capture_output=True,
                                    env=dict(environment, CES_TEST_HTTP_EXIT=exit_code, CES_TEST_HTTP_BODY=body))
            assert (result.returncode == 0) == should_pass, (variable, exit_code, result.stdout, result.stderr)
            assert ('WORKLOAD_VALIDATED' in result.stdout) == should_pass
print('PASS: actual PowerShell cloud-init rendering, difficult passwords, DHCP, shell/JavaScript syntax and Linux HTTP failure handling.')

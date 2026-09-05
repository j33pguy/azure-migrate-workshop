"""Check rendered cloud-init YAML and extracted JavaScript without executing setup."""
import json
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
for extra in [node, nginx]:
    for password in ['Special:<>&"\'${1} #[]{}\\`Password42', 'Ordinary-Password234']:
        rendered = literal('userData').replace('__PASSWORD__', json.dumps(password)).replace('__USER__', 'labadmin').replace('__PKGYAML__', '  - curl\n  - walinuxagent').replace('__RUNYAML__', network_prepare + '\n' + extra)
        data = yaml.safe_load(rendered)
        assert data['password'] == password
        assert data['users'][0]['plain_text_passwd'] == password
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
print('PASS: cloud-init YAML, difficult passwords, DHCP network config, shell fragments, package JSON and JavaScript syntax.')

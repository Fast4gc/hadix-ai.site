#!/usr/bin/env bash
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo 'Execute com sudo.' >&2; exit 1; }
python3 - "${1:-/opt/hadix/backend}" <<'PY'
import os, pathlib, re, shutil, subprocess, sys, tempfile
backend = pathlib.Path(sys.argv[1]).resolve(strict=True)
assert (backend / 'compose.yaml').is_file(), 'compose.yaml ausente'
env = backend / '.env'
original = env.read_text()
matches = re.findall(r'^OLLAMA_MODEL=(.*)$', original, re.M)
assert len(matches) == 1 and matches[0].strip().strip('\"\'') in ('qwen3:4b', 'hadix-qwen3-chat:latest'), 'Modelo configurado diferente; nada foi alterado.'
compose = ['docker', 'compose', '--project-directory', str(backend)]
def run(args, **kwargs):
    return subprocess.run(compose + args, check=True, text=True, **kwargs)
template = run(['exec', '-T', 'ollama', 'ollama', 'show', '--template', 'qwen3:4b'], capture_output=True).stdout
tail = '<think>\n{{ end }}\n{{- end }}'
assert template.rstrip().endswith(tail), 'Template diferente do diagnosticado; nada foi alterado.'
fixed = template.rstrip()[:-len(tail)] + '<think>\n\n</think>\n\n{{ end }}\n{{- end }}\n'
assert '\"\"\"' not in fixed
modelfile = 'FROM qwen3:4b\nTEMPLATE """' + fixed + '"""\n'
run(['exec', '-T', 'ollama', 'sh', '-c', 'cat > /tmp/HadixChat.Modelfile'], input=modelfile)
run(['exec', '-T', 'ollama', 'ollama', 'create', 'hadix-qwen3-chat:latest', '-f', '/tmp/HadixChat.Modelfile'])
print('Testando a resposta antes de alterar a API...', flush=True)
run(['exec', '-T', 'api', 'node', '--input-type=module'], input='''
const started=Date.now();
const r=await fetch('http://ollama:11434/api/chat',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({model:'hadix-qwen3-chat:latest',messages:[{role:'user',content:'Responda apenas: Oi!'}],think:false,stream:false,options:{num_predict:32,num_ctx:2048,num_thread:3}}),signal:AbortSignal.timeout(180000)});
if(!r.ok)throw Error('Ollama HTTP '+r.status);
const data=await r.json();
if(!data.message?.content?.trim()||data.message.thinking?.trim()||/<\\/?think>/.test(data.message.content)||data.done_reason==='length')throw Error('Teste inconclusivo; configuracao da API preservada.');
console.log(JSON.stringify({resposta:data.message.content,segundos:(Date.now()-started)/1000}));
''')
# Preserve credentials and permissions; change only the selected model.
assert env.read_text() == original, '.env mudou durante o teste; tente novamente.'
fd, backup = tempfile.mkstemp(prefix='.env.before-qwen-', dir=backend)
os.close(fd)
shutil.copyfile(env, backup)
updated = re.sub(r'^OLLAMA_MODEL=.*$', 'OLLAMA_MODEL=hadix-qwen3-chat:latest', original, flags=re.M)
fd, staged = tempfile.mkstemp(prefix='.env.qwen-', dir=backend)
with os.fdopen(fd, 'w') as f: f.write(updated)
os.chmod(staged, env.stat().st_mode & 0o777)
os.chown(staged, env.stat().st_uid, env.stat().st_gid)
os.replace(staged, env)
run(['up', '-d', '--no-deps', 'api'])
print('Concluido. Modelo original preservado. Backup da configuracao: ' + backup)
print('Recarregue o dashboard e crie uma NOVA conversa para testar.')
PY

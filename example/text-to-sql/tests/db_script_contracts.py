# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
"""Run the real guest database script in a disposable root with fixture commands.

The script is the one a Yuruna guest fetches and runs as the harness user. Here its
absolute paths point into a temporary root, and fixture sudo, psql, getent, chmod and
friends sit first on PATH to record every argument list and everything psql reads on
standard input. openssl is the real one. The contract: the role password is new on
every run, is hexadecimal, and is never in an argument list, an output stream or an
xtrace; it reaches psql only on standard input; and a one-line owner-only copy is left
for the workload step.

Run with: python db_script_contracts.py
On Windows the script runs under Git for Windows' usr/bin/bash.exe (DB_SCRIPT_BASH names
another bash). Set TEXT_TO_SQL_ROOT to the example/text-to-sql folder of an altered copy
to check that the tests notice the alteration.
"""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(os.environ.get('TEXT_TO_SQL_ROOT') or Path(__file__).resolve().parents[1])
SCRIPT = ROOT / 'test/ubuntu.server.24/ubuntu.server.24.workload.k8s.text-to-sql.db.sh'
SCHEMA = ROOT / 'db/schema.sql'
PERMISSIONS = ROOT / 'db/test-agent-permissions.sql'
USER = 'fixtureuser'
NODE_IP = '10.0.0.5'
# Built from two halves so that this file does not hold the well-known demo password either.
DEMO_PASSWORD = 'agent_demo_' + 'password'


def find_bash():
    """Git's usr/bin bash on Windows, never the bin/bash.exe wrapper, which puts the real
    /usr/bin ahead of the fixture directory so that fixture commands lose to the real ones."""
    if os.name != 'nt':
        return shutil.which('bash') or '/bin/bash'
    candidates = [Path(os.environ[name]) / 'Git' for name in ('ProgramFiles', 'ProgramW6432') if name in os.environ]
    git = shutil.which('git')
    if git:
        candidates = list(Path(git).resolve().parents) + candidates
    candidates.append(Path(r'C:\Program Files\Git'))
    for base in candidates:
        bash = base / 'usr/bin/bash.exe'
        if bash.exists():
            return str(bash)
    raise RuntimeError("Git for Windows' usr/bin/bash.exe was not found")


BASH = os.environ.get('DB_SCRIPT_BASH') or find_bash()


def msys(path):
    """Spelling of a path that scripts can use under Git Bash, where C:/x is /c/x. A drive
    colon would also break the script's own cut -d: on the passwd line."""
    text = Path(path).as_posix()
    if os.name == 'nt' and re.match(r'^[A-Za-z]:/', text):
        return '/' + text[0].lower() + text[2:]
    return text


RECORD = r'''
printf '%s' "${0##*/}" >> "$FIXTURE/argv.log"
for a in "$@"; do printf '\t%s' "$a" >> "$FIXTURE/argv.log"; done
printf '\n' >> "$FIXTURE/argv.log"
'''

# psql records its argument list, the password variable it was given, and standard input when it is
# asked to read a script from it. It models just enough of a server: ALTER ROLE stores the password
# and a TCP login (-h) succeeds only with that password.
PSQL = RECORD + r'''
n=$(( $(cat "$FIXTURE/psql.count" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$FIXTURE/psql.count"
[ -n "${PGPASSWORD+x}" ] && printf '%s\n' "$PGPASSWORD" > "$FIXTURE/psql.$n.pgpassword"
from_stdin=0; previous=
for a in "$@"; do
  if [ "$previous" = -f ] && [ "$a" = - ]; then from_stdin=1; fi
  previous=$a
done
if [ "$from_stdin" = 1 ]; then
  cat > "$FIXTURE/psql.$n.stdin"
  if grep -q "PASSWORD '" "$FIXTURE/psql.$n.stdin"; then
    if [ -n "${FAIL_ALTER:-}" ]; then
      # Like psql, quote the offending statement in the error report.
      { echo 'ERROR:  fixture failure'; printf 'LINE 4: '; grep "PASSWORD '" "$FIXTURE/psql.$n.stdin"; } >&2
      exit 3
    fi
    sed -n "s/.*PASSWORD '\([^']*\)'.*/\1/p" "$FIXTURE/psql.$n.stdin" > "$FIXTURE/server.password"
  fi
  exit 0
fi
case " $* " in
  *" -h "*)
    if [ "${PGPASSWORD:-}" = "$(cat "$FIXTURE/server.password" 2>/dev/null)" ] && [ -n "${PGPASSWORD:-}" ]; then echo 5; exit 0; fi
    echo 'psql: error: password authentication failed' >&2
    exit 2 ;;
  *"SHOW server_version"*) echo 18.0 ;;
  *"count(*) FROM customer"*) echo 5 ;;
  *) echo 1 ;;
esac
'''

COMMANDS = {
    # sudo -u postgres psql ... -> psql ...: drop the options, keep the command.
    'sudo': RECORD + r'''
while [ $# -gt 0 ]; do
  case "$1" in -u|-g|-U) shift 2 ;; -*) shift ;; *) break ;; esac
done
exec "$@"
''',
    'psql': PSQL,
    'createdb': RECORD,
    'pg_ctlcluster': RECORD,
    'pg_lsclusters': RECORD,
    'chown': RECORD,
    # chmod runs for real so that a filesystem with POSIX modes can be checked as well.
    'chmod': RECORD + 'exec "$REAL_CHMOD" "$@"\n',
    'getent': 'echo "$FIXTURE_USER:x:1000:1000::$FIXTURE_HOME:/bin/bash"\n',
    'ip': f'echo "1.1.1.1 via 10.0.0.1 dev eth0 src {NODE_IP} uid 1000"\n',
    'sleep': ':\n',
}


class Sandbox:
    """A disposable root, a copy of the script confined to it, and the logs the fixtures write."""

    def __init__(self, directory, openssl=None):
        self.root = Path(directory)
        posix = msys(self.root)
        self.log = self.root / 'log'
        self.home = self.root / 'home' / USER
        self.sidecar = self.home / '.text-to-sql' / 'agent_ro.password'
        for folder in ['bin', 'log', 'etc/postgresql/18/main', 'usr/local/lib/yuruna', 'var/log/postgresql']:
            (self.root / folder).mkdir(parents=True, exist_ok=True)
        db = self.home / 'yuruna/project/example/text-to-sql/db'
        db.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(SCHEMA, db / 'schema.sql')
        shutil.copyfile(PERMISSIONS, db / 'test-agent-permissions.sql')
        (self.root / 'usr/local/lib/yuruna/yuruna-retry.sh').write_bytes(b'# fixture retry library\n')
        (self.root / 'etc/postgresql/18/main/postgresql.conf').write_bytes(b"#listen_addresses = 'localhost'\nssl = on\n")
        (self.root / 'etc/postgresql/18/main/pg_hba.conf').write_bytes(b'local all all peer\n')
        source = SCRIPT.read_text(encoding='utf-8')
        # Paths are spliced in POSIX form so the same file runs under Git Bash and on Linux.
        for prefix in ['/usr/local', '/etc/postgresql', '/var/log/postgresql']:
            source = source.replace(prefix, posix + prefix)
        # Nothing may reach outside the root, whatever a later edit of the script does.
        stray = re.findall(r'(?<!' + re.escape(posix) + r')/(?:etc|usr/local|var/log)/\S*', source)
        if stray:
            raise AssertionError(f'the script names paths the sandbox does not cover: {stray}')
        self.script = self.root / 'db.sh'
        self.script.write_bytes(source.replace('\r\n', '\n').encode())
        commands = dict(COMMANDS)
        if openssl is not None:
            commands['openssl'] = openssl
        for name, body in commands.items():
            path = self.root / 'bin' / name
            path.write_bytes(('#!/bin/sh\n' + body).replace('\r\n', '\n').encode())
            path.chmod(0o755)
        tools = os.pathsep.join([str(Path(BASH).parent), os.environ.get('PATH', '')])
        real_chmod = shutil.which('chmod', path=tools)
        env = {key: value for key, value in os.environ.items() if key.upper() not in ('SUDO_USER', 'PGPASSWORD')}
        env.update({
            'FIXTURE': msys(self.log), 'FIXTURE_USER': USER, 'FIXTURE_HOME': msys(self.home),
            'REAL_CHMOD': msys(real_chmod), 'USER': USER,
            'PATH': os.pathsep.join([str(self.root / 'bin'), tools]),
        })
        self.env = env

    def run(self, xtrace=False, fail_alter=False):
        env = dict(self.env)
        if fail_alter:
            env['FAIL_ALTER'] = '1'
        command = [BASH] + (['-x'] if xtrace else []) + [msys(self.script)]
        return subprocess.run(command, env=env, capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=600)

    def argv(self):
        path = self.log / 'argv.log'
        return path.read_text(encoding='utf-8') if path.exists() else ''

    def stdin_captures(self):
        """What psql read from standard input, in call order."""
        files = sorted(self.log.glob('psql.*.stdin'), key=lambda p: int(p.name.split('.')[1]))
        return [p.read_text(encoding='utf-8') for p in files]

    def password_statements(self):
        """The scripts psql read that set a password: the role's ALTER ROLE, nothing in the schema."""
        return [text for text in self.stdin_captures() if "PASSWORD '" in text]

    def sidecar_text(self):
        return self.sidecar.read_bytes().decode('utf-8')


class StandardRuns(unittest.TestCase):
    """Two ordinary runs in one root: the second is the rerun against a role that already exists."""

    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.directory.cleanup)
        cls.box = Sandbox(cls.directory.name)
        cls.first = cls.box.run()
        cls.first_password = cls.box.sidecar_text().strip() if cls.box.sidecar.exists() else ''
        cls.second = cls.box.run()
        cls.second_password = cls.box.sidecar_text().strip() if cls.box.sidecar.exists() else ''

    def test_both_runs_succeed(self):
        for result in (self.first, self.second):
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('text-to-sql PostgreSQL ready', self.second.stdout)

    def test_the_password_is_48_hex_characters_and_new_on_every_run(self):
        for password in (self.first_password, self.second_password):
            self.assertRegex(password, r'^[0-9a-f]{48}$')
        self.assertNotEqual(self.first_password, self.second_password)

    def test_the_password_is_in_no_argument_list_and_no_output(self):
        argv = self.box.argv()
        self.assertIn('sudo\t-u\tpostgres\tpsql', argv, 'the fixtures recorded nothing, so the test proves nothing')
        for password in (self.first_password, self.second_password):
            self.assertNotIn(password, argv)
            for result in (self.first, self.second):
                self.assertNotIn(password, result.stdout)
                self.assertNotIn(password, result.stderr)

    def test_the_password_reaches_psql_only_on_standard_input(self):
        statements = self.box.password_statements()
        self.assertEqual(len(statements), 2, 'one ALTER ROLE per run')
        for statement, password in zip(statements, (self.first_password, self.second_password)):
            self.assertIn(f"ALTER ROLE yuruna_agent_ro LOGIN PASSWORD '{password}';", statement)
            lines = statement.splitlines()
            alter = next(i for i, line in enumerate(lines) if line.startswith('ALTER ROLE'))
            # The session stops the server from logging the statement text before it sends it.
            self.assertIn("SET log_statement = 'none';", lines[:alter])
            self.assertIn("SET log_min_error_statement = 'panic';", lines[:alter])
        # Every script psql was handed on standard input was started with exactly these arguments:
        # no -c, and nothing else that could carry the statement.
        psql_calls = [line for line in self.box.argv().splitlines() if line.startswith('psql\t') and '\t-f\t-' in line]
        self.assertGreaterEqual(len(psql_calls), 6, 'schema, permission check and ALTER ROLE, once per run')
        self.assertEqual(set(psql_calls), {'psql\t-v\tON_ERROR_STOP=1\t-d\tyuruna_demo\t-f\t-'})

    def test_the_copy_for_the_workload_step_is_one_line_equal_to_the_applied_password(self):
        data = self.box.sidecar.read_bytes()
        self.assertEqual(data, self.second_password.encode() + b'\n')
        self.assertEqual(data.count(b'\n'), 1)
        self.assertEqual((self.box.log / 'server.password').read_text().strip(), self.second_password)
        self.assertIn(f"'{self.second_password}'", self.box.password_statements()[-1])

    def test_the_tcp_probe_passes_the_stored_password_through_the_environment_only(self):
        self.assertIn(f'yuruna_agent_ro TCP login over {NODE_IP}:5432 OK', self.second.stdout)
        self.assertNotIn('WARNING', self.second.stderr)
        passwords = {p.name: p.read_text().strip() for p in self.box.log.glob('psql.*.pgpassword')}
        # Only the probe was given PGPASSWORD, once per run, and it was the stored password.
        self.assertEqual(sorted(passwords.values()), sorted([self.first_password, self.second_password]))
        probes = [line for line in self.box.argv().splitlines() if line.startswith('psql\t-w\t-h\t' + NODE_IP)]
        self.assertEqual(len(probes), 2, 'the probe must not prompt and must dial the node address')

    def test_directory_and_file_are_restricted_and_handed_to_the_harness_user(self):
        argv = self.box.argv().splitlines()
        directory, file = msys(self.box.sidecar.parent), msys(self.box.sidecar)
        self.assertIn(f'chmod\t700\t{directory}', argv)
        self.assertIn(f'chmod\t600\t{file}', argv)
        self.assertIn(f'chown\t{USER}:\t{directory}\t{file}', argv)

    def test_schema_is_loaded_without_any_password(self):
        loaded = self.box.stdin_captures()[0]
        self.assertEqual(loaded.replace('\r\n', '\n'), SCHEMA.read_text(encoding='utf-8').replace('\r\n', '\n'))
        self.assertNotRegex(loaded, r"(?i)\bpassword\b\s*'")
        self.assertNotIn(DEMO_PASSWORD, loaded)


class OtherScenarios(unittest.TestCase):
    def test_a_sidecar_that_pre_existed_is_replaced_not_appended(self):
        with tempfile.TemporaryDirectory() as directory:
            box = Sandbox(directory)
            box.sidecar.parent.mkdir(parents=True)
            box.sidecar.write_bytes(b'stale-value\nsecond line\n')
            result = box.run()
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertRegex(box.sidecar_text(), r'^[0-9a-f]{48}\n$')

    @unittest.skipIf(os.name == 'nt', 'this filesystem cannot hold POSIX modes (Git Bash on NTFS reports 755/644 for everything); '
                                      'the chmod and chown calls are asserted from the recorded argument lists instead')
    def test_modes_on_a_posix_filesystem_even_when_the_files_pre_existed_loosely(self):
        with tempfile.TemporaryDirectory() as directory:
            box = Sandbox(directory)
            box.sidecar.parent.mkdir(parents=True)
            box.sidecar.parent.chmod(0o755)
            box.sidecar.write_bytes(b'stale\n')
            box.sidecar.chmod(0o644)
            result = box.run()
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(box.sidecar.parent.stat().st_mode & 0o777, 0o700)
            self.assertEqual(box.sidecar.stat().st_mode & 0o777, 0o600)

    def test_a_fresh_directory_and_file_are_created_under_a_restrictive_umask(self):
        text = SCRIPT.read_text(encoding='utf-8')
        self.assertRegex(text, r'umask 077\n\s+mkdir -p "\$APP_PW_DIR"', 'the directory must be created under umask 077')
        self.assertRegex(text, r'rm -f "\$APP_PW_FILE"\n\s+printf [^\n]+> "\$APP_PW_FILE"', 'the file must be created fresh under that umask')

    def test_xtrace_never_shows_the_password_and_comes_back_on_afterwards(self):
        with tempfile.TemporaryDirectory() as directory:
            box = Sandbox(directory)
            result = box.run(xtrace=True)
            self.assertEqual(result.returncode, 0, result.stderr[-2000:])
            password = box.sidecar_text().strip()
            self.assertNotIn(password, result.stderr)
            self.assertNotIn(password, result.stdout)
            # Tracing was on when the secret regions started and is on again after each of them.
            trace = result.stderr
            self.assertIn('+ set_app_role_password', trace)
            self.assertIn('+ app_role_tcp_login 10.0.0.5', trace)
            start, end = trace.index('+ set +x'), trace.index("+ echo '  yuruna_agent_ro password set")
            self.assertGreater(end, start)
            # Nothing at all was traced between them: not the generator, not the SQL, not the file write.
            for word in ('openssl', 'printf', 'ALTER', 'PASSWORD', 'agent_ro.password'):
                self.assertNotIn(word, trace[start:end])
            self.assertRegex(trace[end:], r"\+ echo '\s+yuruna_agent_ro TCP login over")
            self.assertNotIn('PGPASSWORD', trace)

    def test_a_failing_psql_neither_prints_the_password_nor_leaves_a_copy(self):
        with tempfile.TemporaryDirectory() as directory:
            box = Sandbox(directory)
            result = box.run(fail_alter=True)
            self.assertNotEqual(result.returncode, 0)
            password = re.search(r"PASSWORD '([0-9a-f]+)'", box.password_statements()[0]).group(1)
            self.assertNotIn(password, result.stdout)
            self.assertNotIn(password, result.stderr)
            self.assertNotIn(password, box.argv())
            self.assertIn('could not set the yuruna_agent_ro password', result.stderr)
            self.assertIn('<redacted>', result.stderr, "psql's report quotes the statement and must be redacted")
            self.assertFalse(box.sidecar.exists(), 'a password the server never accepted must not be stored')

    def test_output_that_is_not_hex_is_refused_before_it_can_reach_sql(self):
        with tempfile.TemporaryDirectory() as directory:
            box = Sandbox(directory, openssl='''echo "abc'; ALTER ROLE postgres SUPERUSER; --"\n''')
            result = box.run()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('openssl did not return', result.stderr)
            self.assertEqual(box.password_statements(), [])
            self.assertFalse(box.sidecar.exists())


class CommittedFiles(unittest.TestCase):
    def test_the_schema_creates_the_role_without_a_password_and_keeps_the_hardening(self):
        text = SCHEMA.read_text(encoding='utf-8')
        self.assertNotIn(DEMO_PASSWORD, text)
        self.assertNotRegex(text, r"(?i)\bpassword\b\s*'")
        self.assertIn('CREATE ROLE yuruna_agent_ro LOGIN;', text)
        self.assertIn('ALTER ROLE yuruna_agent_ro NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS NOINHERIT;', text)
        self.assertIn('ALTER ROLE yuruna_agent_ro SET default_transaction_read_only = on;', text)

    def test_no_file_that_ships_with_the_example_carries_the_demo_password(self):
        paths = [SCRIPT, SCHEMA, ROOT / 'README.md', ROOT / 'workloads/frontend/text-to-sql-ui/templates/01-text-to-sql-ui.yml',
                 ROOT / 'components/frontend/text-to-sql-ui/appsettings.json', ROOT / 'components/frontend/text-to-sql-ui/Program.cs']
        translated = ROOT.parents[1] / 'docs/pt-BR/example/text-to-sql/README.md'
        if translated.exists():
            paths.append(translated)
        for path in paths:
            self.assertNotIn(DEMO_PASSWORD, path.read_text(encoding='utf-8'), str(path))

    def test_the_script_defines_no_fixed_password(self):
        text = SCRIPT.read_text(encoding='utf-8')
        self.assertNotRegex(text, r'(?m)^\s*APP_PW=["\'][^"\']')
        self.assertNotRegex(text, r'PGPASSWORD=["\']?[A-Za-z0-9_]+["\']?\s')


if __name__ == '__main__':
    unittest.main()

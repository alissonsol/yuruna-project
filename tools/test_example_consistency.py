# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
# GUID: 42bcbf63-32cc-455f-a16d-2f97d9b752d8
"""Check shared example contracts; OS and application identities remain local."""

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[1]
WEBSITE = ROOT / "example/website"
TEXT_TO_SQL = ROOT / "example/text-to-sql"
WORKLOADS = [
    WEBSITE / f"test/ubuntu.server.{release}/ubuntu.server.{release}.workload.k8s.website.sh"
    for release in (24, 26)
] + [TEXT_TO_SQL / "test/ubuntu.server.24/ubuntu.server.24.workload.k8s.text-to-sql.sh"]
DATABASE = TEXT_TO_SQL / "test/ubuntu.server.24/ubuntu.server.24.workload.k8s.text-to-sql.db.sh"
BASH = shutil.which("bash")
DEPLOYMENTS = [WEBSITE / "workloads/frontend/website/templates/01-website.yml",
               TEXT_TO_SQL / "workloads/frontend/text-to-sql-ui/templates/01-text-to-sql-ui.yml"]
STANDALONE_POD = WEBSITE / "components/frontend/website/website-pod.yaml"
LOCAL_WORKLOADS = [WEBSITE / "config/localhost/workloads.yml", TEXT_TO_SQL / "config/localhost/workloads.yml"]
# Deployment entries only text-to-sql has, because only it reads a database.
TEXT_TO_SQL_ONLY_DEPLOYMENTS = """    # Same ordering and secrecy rules for the database password: the script reads the
    # owner-only file that the database setup step wrote and sends the Secret to kubectl
    # on standard input.
    - shell: "& '${env:project_root}/components/frontend/website/create-db-secret.ps1' -Namespace ${env:namespace} -SecretName ${env:appDbSecret}"
"""
PWSH = shutil.which("pwsh")


# --- REGION: read_source
def read_source(path):
    return path.read_text(encoding="utf-8")


# --- REGION: source_without_identity
def source_without_identity(text):
    return re.sub(r"(?m)^(?:\.GUID |# GUID: |sequenceGuid: |sequenceRevision: ).*\n", "", text)


# --- REGION: guest_user_region
def guest_user_region(path):
    text = read_source(path)
    return text.split("# --- REGION: Resolve guest user\n", 1)[1].split("\n# --- REGION:", 1)[0].strip()


# --- REGION: workloads_as_website
def workloads_as_website(text):
    for name, website in (("text-to-sql-ui", "website"), ("text-to-sql", "website"), ("appPodCertSecret", "websitePodCertSecret"),
                          ("appTlsSecret", "websiteTlsSecret"), ("appDomain", "websiteDomain"), ("appHost", "websiteHost")):
        text = text.replace(name, website)
    return text


# --- REGION: global_variables
def global_variables(text):
    block = text.split("\nglobalVariables:\n", 1)[1].split("\n\n", 1)[0]
    return dict(re.findall(r'(?m)^  ([A-Za-z_][\w-]*):\s+(.+?)\s*$', block))


# --- REGION: yaml_key_block
def yaml_key_block(text, name, indentation):
    lines = text.splitlines()
    prefix = " " * indentation
    marker = prefix + name + ":"
    matches = [index for index, line in enumerate(lines) if line == marker]
    if len(matches) != 1:
        raise AssertionError(f"Expected one {name!r} key at indent {indentation}, found {len(matches)}")
    block = [marker]
    for line in lines[matches[0] + 1:]:
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        depth = len(line) - len(line.lstrip())
        if depth < indentation or depth == indentation and not line.lstrip().startswith("-"):
            break
        block.append(line)
    return textwrap.dedent("\n".join(block))


# --- REGION: ExampleConsistency
class ExampleConsistency(unittest.TestCase):
    def test_website_releases_share_the_deployment_script(self):
        self.assertEqual(source_without_identity(read_source(WORKLOADS[0])), source_without_identity(read_source(WORKLOADS[1])))

    def test_applications_share_deployment_phases(self):
        website = source_without_identity(read_source(WORKLOADS[0]))
        application = source_without_identity(read_source(WORKLOADS[2])).replace("text-to-sql-ui", "website").replace("text-to-sql", "website")
        self.assertEqual(website, application)
        self.assertEqual(re.findall(r"(?m)^# --- REGION: (.+)$", website), [
            "Initialize environment", "Resolve guest user", "Prepare Kubernetes configuration",
            "Prepare container registry", "Set resource", "Set component", "Set workload", "Wait for readiness",
        ])

    def test_build_wrappers_share_the_same_contract(self):
        for name in ("copy-pfx.ps1", "create-cert-secret.ps1", "seed-base-images.ps1"):
            with self.subTest(wrapper=name):
                website = read_source(WEBSITE / "components/frontend/website" / name)
                application = read_source(TEXT_TO_SQL / "components/frontend/text-to-sql-ui" / name)
                self.assertEqual(source_without_identity(website), source_without_identity(application))

    def test_local_deployments_share_every_step_but_the_database_secret(self):
        website, application = (read_source(path).split("\n  deployments:\n", 1)[1] for path in LOCAL_WORKLOADS)
        application = workloads_as_website(application)
        self.assertEqual(application.count(TEXT_TO_SQL_ONLY_DEPLOYMENTS), 1, "the declared text-to-sql step moved or changed")
        self.assertEqual(website, application.replace(TEXT_TO_SQL_ONLY_DEPLOYMENTS, ""))

    def test_local_deployments_share_their_infrastructure_variables(self):
        website, application = (global_variables(read_source(path)) for path in LOCAL_WORKLOADS)
        shared = ("certManagerIssuerEmail", "_registryLocation", "dockerServer", "dockerUsername", "dockerPassword",
                  "ingressClass", "ingressChartVersion", "ingressChartSha256")
        for name in shared:
            with self.subTest(variable=name):
                self.assertIn(name, website)
                self.assertEqual(website[name], application.get(name))
        self.assertRegex(website["ingressChartVersion"], r'^"\d+\.\d+\.\d+"$')
        self.assertRegex(website["ingressChartSha256"], r'^"[0-9a-f]{64}"$')

    def test_ingress_chart_installs_only_the_downloaded_file_that_matches_its_digest(self):
        deployments = read_source(LOCAL_WORKLOADS[0]).split("\n  deployments:\n", 1)[1]
        pull = '- helm: "pull ingress-nginx/ingress-nginx --version ${env:ingressChartVersion} --destination ."'
        check = re.search(r'(?m)^    - shell: "(if \(\(Get-FileHash .+)"$', deployments)
        install = "install nginx-ingress ./ingress-nginx-${env:ingressChartVersion}.tgz"
        self.assertIsNotNone(check)
        self.assertLess(deployments.index(pull), deployments.index(check.group(0)))
        self.assertLess(deployments.index(check.group(0)), deployments.index(install))
        self.assertNotIn("install nginx-ingress ingress-nginx/ingress-nginx", deployments)
        if not PWSH:
            self.skipTest("pwsh runs the digest step; the order of the steps was checked")
        import hashlib
        with tempfile.TemporaryDirectory(prefix="yuruna-example-chart-") as temporary:
            chart = Path(temporary, "ingress-nginx-9.8.7.tgz")
            chart.write_bytes(b"fixture chart bytes")
            digest = hashlib.sha256(chart.read_bytes()).hexdigest()
            # The deployment engine expands the value as a double-quoted string, then evaluates it.
            command = "$e = $ExecutionContext.InvokeCommand.ExpandString($env:STEP); Invoke-Expression $e"
            for label, pinned, expected_exit in (("matching file", digest, 0), ("altered file", "0" * 64, 1)):
                with self.subTest(case=label):
                    env = dict(os.environ, STEP=check.group(1).replace('\\"', '"'), ingressChartVersion="9.8.7",
                               ingressChartSha256=pinned)
                    result = subprocess.run([PWSH, "-NoProfile", "-NonInteractive", "-Command", command], cwd=temporary,
                                            env=env, capture_output=True, text=True, timeout=120)
                    self.assertEqual(result.returncode, expected_exit, result.stdout + result.stderr)
                    if expected_exit:
                        self.assertIn("does not match its pinned SHA-256", result.stdout + result.stderr)

    def test_local_resources_differ_only_by_project(self):
        self.assertEqual(source_without_identity(read_source(WEBSITE / "config/localhost/resources.yml")),
                         source_without_identity(read_source(TEXT_TO_SQL / "config/localhost/resources.yml")).replace('"text-to-sql"', '"website"'))

    def test_website_sequences_differ_only_by_release_and_identity(self):
        for suffix in ("yml", "ssh.yml", "baseline.ssh.yml", "warm.ssh.yml"):
            with self.subTest(sequence=suffix):
                normalized = []
                for release in (24, 26):
                    path = WEBSITE / f"test/workload.guest.ubuntu.server.{release}.k8s.website.{suffix}"
                    text = source_without_identity(read_source(path))
                    for value in (f"ubuntu.server.{release}", f"{release}.04", f"yuuser{release}",
                                  f"yuhost{release}", f"yuwebsite{release}", f"ubuntu{release}"):
                        text = text.replace(value, value.replace(str(release), "RELEASE"))
                    normalized.append(text)
                self.assertEqual(*normalized)

    def test_snapshot_producer_and_consumer_declare_the_shared_installers(self):
        for release in (24, 26):
            with self.subTest(release=release):
                inputs = []
                for kind in ("baseline", "warm"):
                    path = WEBSITE / f"test/workload.guest.ubuntu.server.{release}.k8s.website.{kind}.ssh.yml"
                    source_files = yaml_key_block(read_source(path), "sourceFiles", 2)
                    self.assertEqual(source_files.count("- guest/shared/ubuntu.*.sh"), 1)
                    inputs.append(source_files)
                self.assertEqual(*inputs)

    def test_every_entrypoint_resolves_the_same_guest_home(self):
        expected = guest_user_region(WORKLOADS[0])
        for path in WORKLOADS + [DATABASE]:
            with self.subTest(script=path.name):
                self.assertEqual(guest_user_region(path), expected)

    def test_helm_deployments_share_transport_and_certificate_blocks(self):
        website, application = map(read_source, DEPLOYMENTS)
        for name, indentation in (("ports", 8), ("resources", 8), ("volumeMounts", 8),
                                  ("readinessProbe", 8), ("livenessProbe", 8),
                                  ("imagePullSecrets", 6), ("securityContext", 6), ("volumes", 6)):
            with self.subTest(block=name):
                app_block = yaml_key_block(application, name, indentation)
                if name == "resources":
                    app_block = app_block.replace('memory: "128Mi"', 'memory: "256Mi"')
                self.assertEqual(yaml_key_block(website, name, indentation), app_block)

    def test_all_pod_forms_use_bounded_tls_readiness_and_tcp_liveness(self):
        expected_readiness = """readinessProbe:
  httpGet:
    path: /
    port: 443
    scheme: HTTPS
  initialDelaySeconds: 5
  periodSeconds: 5
  failureThreshold: 12"""
        expected_liveness = """livenessProbe:
  tcpSocket:
    port: 443
  initialDelaySeconds: 60
  periodSeconds: 10
  failureThreshold: 6"""
        for path, indentation in [(path, 8) for path in DEPLOYMENTS] + [(STANDALONE_POD, 6)]:
            with self.subTest(manifest=path.name):
                source = read_source(path)
                self.assertEqual(yaml_key_block(source, "readinessProbe", indentation), expected_readiness)
                self.assertEqual(yaml_key_block(source, "livenessProbe", indentation), expected_liveness)

    def test_standalone_website_keeps_the_deployment_resource_and_key_access_budget(self):
        website, standalone = read_source(DEPLOYMENTS[0]), read_source(STANDALONE_POD)
        for name, deployment_indent, standalone_indent in (("resources", 8, 6), ("securityContext", 6, 2)):
            with self.subTest(block=name):
                self.assertEqual(yaml_key_block(website, name, deployment_indent),
                                 yaml_key_block(standalone, name, standalone_indent))
        self.assertIn('value: "8001"', yaml_key_block(standalone, "env", 6))

    def test_ingresses_share_the_same_tls_and_http_smoke_contract(self):
        website = source_without_identity(read_source(WEBSITE / "workloads/frontend/website/templates/03-ingress-to-website-with-tls.yml"))
        application = source_without_identity(read_source(TEXT_TO_SQL / "workloads/frontend/text-to-sql-ui/templates/03-ingress-to-text-to-sql-ui-with-tls.yml"))
        application = application.replace("text-to-sql-ui", "website").replace("appHost", "websiteHost").replace("appTlsSecret", "websiteTlsSecret")
        self.assertEqual(website, application)
        self.assertIn('nginx.ingress.kubernetes.io/ssl-redirect: "false"', website)
        self.assertIn('nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"', website)

    def test_ingresses_forward_the_request_path_unchanged(self):
        # ingress-nginx replaces the whole request URI with rewrite-target; without a
        # capture-group reference every page, script and stylesheet request would be
        # answered with the root document.
        for path in (WEBSITE / "workloads/frontend/website/templates/03-ingress-to-website-with-tls.yml",
                     TEXT_TO_SQL / "workloads/frontend/text-to-sql-ui/templates/03-ingress-to-text-to-sql-ui-with-tls.yml"):
            with self.subTest(ingress=path.name):
                for target in re.findall(r"(?m)^\s*nginx\.ingress\.kubernetes\.io/rewrite-target:\s*(\S+)", read_source(path)):
                    self.assertRegex(target, r"\$\d", "rewrite-target without a capture group rewrites every path")

    def test_manifest_regions_name_the_next_yaml_key_exactly(self):
        paths = DEPLOYMENTS + [STANDALONE_POD, WEBSITE / "components/frontend/website/website-service.yaml"]
        paths += list(WEBSITE.glob("workloads/frontend/*/templates/03-*.yml"))
        paths += list(TEXT_TO_SQL.glob("workloads/frontend/*/templates/03-*.yml"))
        for path in paths:
            with self.subTest(manifest=path.name):
                lines = read_source(path).splitlines()
                regions = [(index, re.fullmatch(r"( *)# --- REGION: (.+)", line))
                           for index, line in enumerate(lines) if "# --- REGION:" in line]
                self.assertGreaterEqual(len(regions), 4)
                for index, region in regions:
                    self.assertIsNotNone(region, path)
                    self.assertTrue(lines[index + 1].strip(), f"Blank line after region in {path}:{index + 1}")
                    next_index = index + 1
                    while lines[next_index].lstrip().startswith("#"):
                        next_index += 1
                    self.assertRegex(lines[next_index], "^" + re.escape(region[1] + region[2]) + ":")

    @unittest.skipUnless(BASH and os.name != "nt", "requires a POSIX Bash fixture")
    def test_failure_exits_print_the_record_the_runner_reads(self):
        source = read_source(ROOT / "tools/example-workload.sh")
        snippet = source.split("# --- REGION: example_fail\n", 1)[1].split("\n# --- REGION:", 1)[0]
        result = subprocess.run([BASH, "-c", snippet + "\nexample_fail network_timeout 'a \"quoted\" back\\slash'"],
                                capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 1, "the record ends the script as a failure")
        line = result.stdout.strip()
        self.assertTrue(line.startswith("YURUNA_RESULT "), line)
        record = json.loads(line[len("YURUNA_RESULT "):])
        self.assertEqual(record["canonicalFailureClass"], "network_timeout")
        self.assertEqual(record["errorMessage"], 'a "quoted" back\\slash')
        self.assertIs(record["success"], False)
        classes = set(re.findall(r"(?m)^\s*example_fail (\S+) ", source))
        self.assertTrue(classes, "the failure exits name their class")
        taxonomy = ROOT.parent / "yuruna/test/modules/Test.FailureTaxonomy.psm1"
        if taxonomy.exists():
            block = read_source(taxonomy).split("$script:FailureClassEnum = @(", 1)[1].split("\n)", 1)[0]
            canonical = set(re.findall(r"'([a-z_]+)'", block))
            self.assertLessEqual(classes, canonical, "the runner files only canonical classes")

    @unittest.skipUnless(BASH and os.name != "nt", "requires a POSIX Bash fixture")
    def test_cache_discovery_preserves_proxy_file_probe_precedence(self):
        source = read_source(ROOT / "tools/example-workload.sh")
        snippet = source.split("# --- REGION: Locate caching proxy\n", 1)[1].split("\n# --- REGION:", 1)[0]
        snippet = snippet.replace("/etc/yuruna/host.env", '"$HOST_ENV_FIXTURE"')
        with tempfile.TemporaryDirectory(prefix="yuruna-example-cache-") as temporary:
            fixture = Path(temporary)
            curl = fixture / "curl"
            curl.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$FIXTURE/probes"\n'
                            'exit "$PROBE_EXIT"\n', encoding="utf-8")
            curl.chmod(0o755)
            host_file = fixture / "host.env"
            probes = fixture / "probes"
            cases = [
                ("proxy before host file", "http://proxy.test:3128", "YURUNA_CACHING_PROXY_SERVICE_IP=file.test", 0, "proxy.test", 0),
                ("HTTPS proxy", "https://secure.test:8443", "", 7, "secure.test", 0),
                ("case-insensitive URI scheme", "HTTPS://secure.test:8443", "", 7, "secure.test", 0),
                ("first host assignment", "", "YURUNA_CACHING_PROXY_SERVICE_IP=first.test\nYURUNA_CACHING_PROXY_SERVICE_IP=second.test", 0, "first.test", 0),
                ("first nonempty host assignment", "", "YURUNA_CACHING_PROXY_SERVICE_IP=\nYURUNA_CACHING_PROXY_SERVICE_IP=file.test", 7, "file.test", 0),
                ("host assignment with comment", "", "YURUNA_CACHING_PROXY_SERVICE_IP=file.test # cache", 7, "file.test", 0),
                ("invalid proxy falls back", "direct", "YURUNA_CACHING_PROXY_SERVICE_IP=file.test", 7, "file.test", 0),
                ("empty proxy host falls back", "http://:3128", "YURUNA_CACHING_PROXY_SERVICE_IP=file.test", 7, "file.test", 0),
                ("empty assignment probes", "", "YURUNA_CACHING_PROXY_SERVICE_IP=", 0, "yuruna-caching-proxy-service", 1),
                ("unrelated assignment probes", "", "OTHER_CACHE=file.test", 0, "yuruna-caching-proxy-service", 1),
                ("absent file probes", "", None, 0, "yuruna-caching-proxy-service", 1),
                ("direct lab has no cache", "", None, 7, "", 1),
            ]
            for label, proxy, contents, probe_exit, expected, probe_count in cases:
                with self.subTest(case=label):
                    if probes.exists():
                        probes.unlink()
                    if contents is None:
                        if host_file.exists():
                            host_file.unlink()
                    else:
                        host_file.write_text(contents, encoding="utf-8")
                    env = dict(os.environ, PATH=str(fixture) + os.pathsep + os.environ["PATH"],
                               FIXTURE=str(fixture), HOST_ENV_FIXTURE=str(host_file),
                               http_proxy=proxy, PROBE_EXIT=str(probe_exit))
                    result = subprocess.run([BASH, "-c", "set -euo pipefail\n" + snippet + '\nprintf "CACHE_HOST=%s\\n" "$CACHE_HOST"\n'],
                                            cwd=fixture, env=env, capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout.splitlines()[-1], "CACHE_HOST=" + expected)
                    calls = read_source(probes).splitlines() if probes.exists() else []
                    self.assertEqual(len(calls), probe_count)
                    for call in calls:
                        self.assertIn("--max-time 10", call)
                        self.assertIn("http://yuruna-caching-proxy-service:5000/v2/", call)

    @unittest.skipUnless(BASH and os.name != "nt", "requires a POSIX Bash fixture")
    def test_base_images_and_their_upstream_come_from_the_dockerfile(self):
        source = read_source(ROOT / "tools/example-workload.sh")
        fail = source.split("# --- REGION: example_fail\n", 1)[1].split("\n# --- REGION:", 1)[0]
        start = source.index("# The Dockerfile is the only place the base-image identity is written")
        end = source.index('LOCAL_REGISTRY="localhost:5000"', start)
        snippet = fail + "\n" + source[start:end] + 'printf "%s\\n" "$BASE_IMAGES_UPSTREAM" "${BASE_IMAGES[@]}"\n'
        self.assertNotIn("dotnet/", snippet, "the helper must not restate an image name")
        examples = [WEBSITE / "components/frontend/website/Dockerfile",
                    TEXT_TO_SQL / "components/frontend/text-to-sql-ui/Dockerfile"]
        cases = [(path.name + " of " + path.parents[3].name, read_source(path), 0,
                  ["mcr.microsoft.com", "dotnet/aspnet:10.0", "dotnet/sdk:10.0"]) for path in examples]
        cases += [
            ("duplicates, flags and case", "ARG REGISTRY=registry.test/\nfrom ${REGISTRY}a:1 AS x\n"
             "FROM --platform=linux/amd64 ${REGISTRY}b:2 AS y\nFROM x AS z\nFROM ${REGISTRY}a:1\n", 0,
             ["registry.test", "a:1", "b:2"]),
            ("no REGISTRY default", "ARG REGISTRY\nFROM ${REGISTRY}a:1\n", 1, None),
            ("no REGISTRY-prefixed image", "ARG REGISTRY=registry.test/\nFROM debian:13\n", 1, None),
        ]
        for label, dockerfile, expected_exit, expected in cases:
            with self.subTest(case=label), tempfile.TemporaryDirectory(prefix="yuruna-example-base-") as temporary:
                Path(temporary, "Dockerfile").write_text(dockerfile, encoding="utf-8")
                result = subprocess.run([BASH, "-c", "set -euo pipefail\n" + snippet], cwd=temporary,
                                        capture_output=True, text=True, timeout=60)
                self.assertEqual(result.returncode, expected_exit, result.stdout + result.stderr)
                if expected is None:
                    self.assertIn('"canonicalFailureClass":"script_error"', result.stdout)
                else:
                    self.assertEqual(result.stdout.splitlines(), expected)

    @unittest.skipUnless(BASH and os.name != "nt", "requires a POSIX Bash fixture")
    def test_registry_is_published_on_the_loopback_address_only(self):
        source = read_source(ROOT / "tools/example-workload.sh").replace("/etc/yuruna/host.env", '"$HOST_ENV_FIXTURE"')
        docker = textwrap.dedent("""\
            #!/bin/sh
            printf '%s\\n' "$*" >> "$FIXTURE/docker.log"
            case "$1" in
              inspect)
                [ -f "$FIXTURE/container" ] || exit 1
                [ "$2" = -f ] && printf '%s \\n' "$(cat "$FIXTURE/container")"
                exit 0 ;;
              start) [ -f "$FIXTURE/container" ] ;;
              rm) rm -f "$FIXTURE/container" ;;
              image) printf 'registry:2\\n' ;;
              run) printf '%s' "$4" > "$FIXTURE/container"; echo fixture-id ;;
              *) exit 0 ;;
            esac
            """)
        cases = [
            ("no container yet", None, True, False),
            ("container published on every address", "", True, True),
            ("container published on another address", "0.0.0.0", True, True),
            ("loopback container is reused", "127.0.0.1", False, False),
        ]
        for label, existing, expect_run, expect_remove in cases:
            with self.subTest(case=label), tempfile.TemporaryDirectory(prefix="yuruna-example-registry-") as temporary:
                fixture = Path(temporary)
                (fixture / "docker").write_text(docker, encoding="utf-8")
                (fixture / "curl").write_text("#!/bin/sh\nexit 7\n", encoding="utf-8")
                for name in ("docker", "curl"):
                    (fixture / name).chmod(0o755)
                if existing is not None:
                    (fixture / "container").write_text(existing, encoding="utf-8")
                env = dict(os.environ, PATH=str(fixture) + os.pathsep + os.environ["PATH"], FIXTURE=str(fixture),
                           HOST_ENV_FIXTURE=str(fixture / "host.env"), http_proxy="")
                result = subprocess.run([BASH, "-c", "set -euo pipefail\n" + source + "\nexample_registry_prepare\n"],
                                        cwd=fixture, env=env, capture_output=True, text=True, timeout=120)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                calls = read_source(fixture / "docker.log").splitlines()
                runs = [call for call in calls if call.startswith("run ")]
                removed = "rm -f registry" in calls[:calls.index("start registry")]
                self.assertEqual(removed, expect_remove, calls)
                if expect_run:
                    self.assertEqual(len(runs), 1, calls)
                    self.assertIn("-p 127.0.0.1:5000:5000 ", runs[0])
                else:
                    self.assertEqual(runs, [], calls)
                self.assertEqual(read_source(fixture / "container"), "127.0.0.1:5000:5000" if expect_run else "127.0.0.1")

    @unittest.skipUnless(BASH and os.name != "nt", "requires a POSIX Bash fixture")
    def test_guest_user_resolution_preserves_literal_paths_and_fails_closed(self):
        with tempfile.TemporaryDirectory(prefix="yuruna-example-user-") as temporary:
            fixture = Path(temporary)
            getent = fixture / "getent"
            getent.write_text('#!/bin/sh\n[ "$1" = passwd ] || exit 8\nprintf "%s" "$2" > "$FIXTURE/username"\n'
                              '[ "${GETENT_FAIL:-0}" = 0 ] || exit 7\n'
                              'printf "%s:x:1000:1000::%s:/bin/bash\\n" "$2" "$FIXTURE_HOME"\n', encoding="utf-8")
            getent.chmod(0o755)
            cases = [
                ("interactive user", "", "/home/interactive", 0, False),
                ("sudo user", "harness", "/home/harness", 0, False),
                ("spaces in home", "harness", "/home/guest with spaces", 0, False),
                ("literal shell text", "harness", "$(touch unexpected-execution)", 0, False),
                ("empty home", "harness", "", 1, False),
                ("failed lookup", "harness", "/home/harness", 7, True),
            ]
            for label, sudo_user, home, expected_exit, failure in cases:
                with self.subTest(case=label):
                    env = dict(os.environ, PATH=str(fixture) + os.pathsep + os.environ["PATH"],
                               USER="interactive", SUDO_USER=sudo_user, FIXTURE=str(fixture),
                               FIXTURE_HOME=home, GETENT_FAIL="1" if failure else "0")
                    snippet = "set -euo pipefail\n" + guest_user_region(WORKLOADS[0]) + '\nprintf "%s\\n%s\\n" "$REAL_USER" "$REAL_HOME"\n'
                    result = subprocess.run([BASH, "-c", snippet], cwd=fixture, env=env, capture_output=True, text=True)
                    self.assertEqual(result.returncode, expected_exit, result.stderr)
                    self.assertEqual(read_source(fixture / "username"), sudo_user or "interactive")
                    if expected_exit == 0:
                        self.assertEqual(result.stdout.splitlines(), [sudo_user or "interactive", home])
                    elif not failure:
                        self.assertIn("no home directory found", result.stderr)
                    self.assertFalse((fixture / "unexpected-execution").exists())


if __name__ == "__main__":
    unittest.main()

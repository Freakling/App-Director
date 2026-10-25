<!-- App Director · framework-owned: replaced on upgrade. -->
# OWASP baseline checklist

The checklist the security assessment (`procedures/security.md`) works through, category by category. It breaks the OWASP baseline in `rules.md` › Architecture defaults into checks a reader can verify. The categories are the OWASP Top 10 (2025) and, for an app that serves an API, the OWASP API Security Top 10 (2023). The checks paraphrase those lists, and OWASP ASVS 5.0 level 1 where a level 1 requirement applies, named in brackets by ASVS chapter. Read the sources for the full text: https://owasp.org/Top10/, https://owasp.org/API-Security/, https://owasp.org/www-project-application-security-verification-standard/.

It is a list of what to look for, not a certification. A check that holds is evidence for its category, never proof that the category is met.

## How to read a check
Each check is marked with where it can be verified:
- **code:** in the source; cite the file and line that holds, or breaks, it.
- **config:** in a manifest, a settings file, a server or platform config, or the deploy files in the repository; cite the file and line.
- **people:** people and process; it can't be verified in the repository. It goes on the director's list (`security.md` step 4), never into a finding.

A check that depends on something the app doesn't have (no sign-in, no file upload, no outbound requests) is not applicable; say which part is missing.

## Where to look, by stack
Start from AGENTS.md › Architecture and `tools/check.cfg` (`[project] stack`, `[ui] dirs`, `[data] dirs`), then:
- **typescript:** the server entry and its routes, handlers and middleware (often `src/server.*`, `src/routes/`, `src/api/`, or `app/` and `pages/api/` in a framework); the data layer for queries; `package.json` and its lock file; framework and server config (headers, CORS, `next.config.*`, `vite.config.*`); `.env.example`.
- **flutter:** `lib/` (the services and repositories that make network and storage calls); `pubspec.yaml` and `pubspec.lock`; `android/app/src/main/AndroidManifest.xml` and `ios/Runner/Info.plist` for permissions, cleartext traffic and exported components. A backend the app calls lives elsewhere, so its server-side checks are not checkable here.
- **python:** the routes or views (`urls.py` and views in Django, routers in FastAPI, blueprints in Flask); settings (`settings.py`, `config.py`, how the environment is loaded); the data layer for queries; `requirements.txt` or `pyproject.toml` and their lock files.
- **none:** whatever the repository holds, such as static pages, scripts and hosting config (headers, redirects).

## OWASP Top 10 (2025)

### A01:2025 Broken Access Control
- code: every route, handler or endpoint that reads or changes non-public data checks who is calling before it acts; look for routes registered without the auth middleware or decorator the others use [ASVS: Authorization].
- code: access to one record checks that the caller owns it or may see it (the query filters by the caller, or the handler compares owner and caller), not only that the caller is signed in [ASVS: Authorization].
- code: access is denied by default, so a new route needs an explicit grant, and role checks happen on the server, never only by hiding a control in the UI [ASVS: Authorization].
- code: the UI doesn't reach the data layer directly (the check's UI purity step covers the import rule only).
- config: CORS allows only the app's own origins, not `*` together with credentials [ASVS: Web Frontend Security].
- people: access to production, hosting, the repository and third-party consoles is reviewed on a schedule and removed when someone leaves.
- code: the server never fetches a URL taken from input without checking it against an allow list of hosts, and never follows one to internal addresses (localhost, private ranges, cloud metadata); this is server-side request forgery, which the 2025 list folds into this category [ASVS: Validation and Business Logic].
- Not applicable (the request-forgery check) when the server makes no outbound request built from input.

### A02:2025 Security Misconfiguration
- config: debug modes, stack traces, default accounts and sample pages are off in the production config [ASVS: Configuration].
- config: security headers are set where the app serves pages (Content-Security-Policy, X-Content-Type-Options, frame protection) [ASVS: Web Frontend Security].
- code: errors returned to clients don't include stack traces, queries or internal paths [ASVS: Security Logging and Error Handling].
- config: mobile manifests ask only for the permissions the app uses, and every exported component is meant to be [ASVS: Configuration].
- people: the production settings are reviewed when the hosting changes.

### A03:2025 Software Supply Chain Failures
- config: dependencies are pinned by a committed lock file, and the manifest doesn't leave versions open (no `*` or `latest`).
- config: the dependency audit (`security.md` step 1) reports no known vulnerability in runtime dependencies, or each one has an accepted decision [ASVS: Configuration].
- config: packages come from known sources: the registries and indexes are named in the project's config (such as `.npmrc` or `pip.conf`), and no dependency is taken from an unpinned git URL or an arbitrary host.
- config: the CI and build files install from the lock file (such as `npm ci`) and pull only from those sources; a build step that downloads and runs a script from a URL is a finding.
- people: someone watches for advisories between assessments and updates dependencies on a schedule, and who may add a new dependency is named.

### A04:2025 Cryptographic Failures
- code: passwords are stored with a slow, salted hash made for passwords (bcrypt, scrypt, Argon2, PBKDF2), never in plain text, encrypted, or with a fast hash [ASVS: Authentication, Cryptography].
- code: no home-made cryptography, no ECB mode, no MD5 or SHA-1 for security, and random values for tokens come from a cryptographically secure generator [ASVS: Cryptography].
- config: traffic is HTTPS only (a redirect to HTTPS, HSTS where the host allows it, no cleartext traffic allowed in the mobile manifests) [ASVS: Secure Communication].
- code: sensitive data (personal data, tokens) isn't written to logs, URLs, or client-side storage that outlives the session [ASVS: Data Protection].
- people: keys and secrets are rotated on a schedule and when anyone with access leaves, and who rotates them is named.

### A05:2025 Injection
- code: database queries take input as parameters (prepared statements, the ORM's query builder), never by concatenating or interpolating input into the query text [ASVS: Encoding and Sanitization].
- code: no input reaches a shell command, `eval`, a template compiled at runtime, or a dynamic import [ASVS: Encoding and Sanitization].
- code: output into HTML is encoded by the framework; look for raw HTML (`dangerouslySetInnerHTML`, `innerHTML`, `v-html`, `|safe`, `mark_safe`) fed by input [ASVS: Encoding and Sanitization].
- code: input is validated on the server against an allow list of types, lengths and formats [ASVS: Validation and Business Logic].

### A06:2025 Insecure Design
- code: limits on business flows that can be abused (sign-up, password reset, vouchers, sending messages) are enforced on the server [ASVS: Validation and Business Logic].
- code: the code does what the security-related lines in `product/decisions.md` say.
- people: a feature that touches security is thought through for misuse (who could abuse it, and how) before it's built; `design.md` states each option's effect on the baseline.

### A07:2025 Authentication Failures
- code: no credentials, keys or tokens in source (the check's secrets step covers this) [ASVS: Configuration].
- code: sign-in is rate limited or locked after repeated failures, and a failed sign-in doesn't say whether the account exists [ASVS: Authentication].
- code: session tokens are random, sent in cookies marked `Secure`, `HttpOnly` and `SameSite`, renewed at sign-in and invalidated at sign-out [ASVS: Session Management].
- code: self-contained tokens (JWT) have their signature and expiry checked, and the algorithm `none` is refused [ASVS: Self-contained Tokens].
- code: password reset tokens are single use and expire [ASVS: Authentication].
- people: the accounts on hosting, the repository and the app stores use multi-factor authentication.

### A08:2025 Software or Data Integrity Failures
- code: untrusted data is never deserialized into objects (`pickle`, `yaml.load` without the safe loader, `eval` of JSON) [ASVS: Encoding and Sanitization].
- config: scripts loaded from a CDN carry an integrity hash, and CI workflows pin third-party actions [ASVS: Web Frontend Security].
- code: webhooks, callbacks and updates from outside are verified (a signature or shared secret) before they're trusted.
- people: who can merge to the main branch and publish releases is limited and reviewed.

### A09:2025 Security Logging and Alerting Failures
- code: sign-ins, failed sign-ins, access denials and permission changes are logged with who and when, without secrets or personal data in the log line [ASVS: Security Logging and Error Handling].
- people: alerts on those logs reach someone, who is on call is named, and an incident response plan says what happens next.

### A10:2025 Mishandling of Exceptional Conditions
- code: errors returned to users are generic; a response doesn't carry a stack trace, a query, a file path or another internal detail (the logs hold them) [ASVS: Security Logging and Error Handling].
- code: an exception in an authorization, authentication or validation path denies the request; look for a `catch` or `except` that falls through to allow it, or returns success [ASVS: Security Logging and Error Handling].
- code: no catch-all handler swallows an error silently (an empty `catch`, `except: pass`, a `.catch(() => {})`); it is handled, or logged and re-thrown, and promise rejections are handled rather than left unhandled.
- code: resources (connections, files, locks, transactions) are released on the error path too (`finally`, `using`, `with`, a rollback), so a failure doesn't leave a half-finished change or a leak.
- code: a failure in one request or background task doesn't take down the process, and a missing or malformed input yields a rejected request, not an undefined state [ASVS: Validation and Business Logic].
- people: unexpected errors reach someone through the alerting in A09.

## OWASP API Security Top 10 (2023)
Only for an app that serves an API (its own backend, or routes another app calls).

### API1:2023 Broken Object Level Authorization
- code: every endpoint that takes an object ID checks that the caller may access that object (as A01's second check).

### API2:2023 Broken Authentication
- code: every non-public endpoint requires authentication, and API keys and tokens are checked on the server (as A07).

### API3:2023 Broken Object Property Level Authorization
- code: responses return only the fields the caller may see (no whole database rows), and updates accept only the fields the caller may change (no mass assignment of `role` or `owner`).

### API4:2023 Unrestricted Resource Consumption
- code: list endpoints are paginated with a maximum page size, request bodies and uploads have size limits, and expensive calls are rate limited.

### API5:2023 Broken Function Level Authorization
- code: admin and other privileged endpoints check the caller's role on the server, not only by an unlisted path.

### API6:2023 Unrestricted Access to Sensitive Business Flows
- code: flows that are costly when automated (purchases, sign-ups, messages) have a limit or an anti-automation step (as A06).

### API7:2023 Server Side Request Forgery
- code: as A01 (its request-forgery check).

### API8:2023 Security Misconfiguration
- config: as A02, with CORS and HTTP methods limited to what each endpoint uses.

### API9:2023 Improper Inventory Management
- config: every endpoint the app serves is documented (an API description or AGENTS.md › Architecture), and old versions and debug endpoints aren't left reachable.
- people: retired environments and hosts are shut down.

### API10:2023 Unsafe Consumption of APIs
- code: data from third-party APIs is validated like input, calls to them use HTTPS and a time limit, and their redirects aren't followed blindly.

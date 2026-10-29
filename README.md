# Hugo + nginx + SSH deployments

One container serves a Hugo site over HTTP and accepts SSH deployment triggers on
port **2222**. CI runs `git pull` over SSH; a forced command performs a fast-forward
pull of the configured branch, downloads Git LFS objects, builds Hugo, and
atomically publishes the result. It does not expose an interactive shell.

## Start

```sh
cp .env.example .env
# Edit .env: repository URL, branch, public site URL, and
# DEPLOY_AUTHORIZED_KEYS="ssh-ed25519 AAAA... your-ci-key"

docker compose up -d --build
docker compose logs -f
```

HTTP is available on host port **8080**; SSH on **2222**. Change the left-hand
port mappings in `compose.yaml` as needed. Put an HTTPS reverse proxy in front of
HTTP for public production use; TLS is not configured in this container.

The initial clone/build runs before either server starts. Failed initial builds
fail the container startup. Later failed builds return a nonzero SSH exit status
and leave the previous successful output live. The latest five successful builds
are retained. Repository data, published output, and SSH host keys persist in the
`site-data` volume. Do not delete that volume unless you intend to reset them.

## Private repositories and LFS

There are two separate SSH key pairs:

- **CI → container:** CI keeps the private key; set `DEPLOY_AUTHORIZED_KEYS`
  to its public key. This is public data, so you can also put it directly in
  `compose.yaml` under `environment`, or bake it into the Dockerfile with
  `ENV DEPLOY_AUTHORIZED_KEYS="ssh-ed25519 AAAA... your-ci-key"`.
  Multiple public keys can be supplied separated by actual newlines.
  The entrypoint also supports the old `/run/secrets/deploy_authorized_keys`
  file as a fallback when the environment variable is unset.
- **Container → Git host:** give the container a separate read-only repository
  deploy key. Put its private key in `secrets/repo_key` and verified Git host
  host-key entries in `secrets/repo_known_hosts`. Uncomment the corresponding
  secret declarations AND service secret entries in `compose.yaml`. Use an SSH
  `REPO_URL`, for example `git@github.com:YOUR-ORG/YOUR-HUGO-SITE.git`.

Use a non-passphrase repository key so unattended fetches work, restrict its
permissions, and never commit it. Obtain/verify Git host fingerprints through a
trusted channel; do not blindly trust `ssh-keyscan` output. Secrets are mounted
at runtime and excluded from the Docker build context.

Git LFS is installed and `git lfs pull` runs before every build, including in
submodules. Your Git/LFS host must support unattended authentication with the
configured credential. Some LFS providers require additional HTTPS credentials;
this example does not provision those. Submodules on other hosts likewise need
appropriate read access and verified host keys.

## Trigger from CI after main changes

Store the CI private key and the container's verified SSH host key in your CI
secret store. For example, inspect the server's public host key on the trusted
Docker host:

```sh
docker compose exec hugo ssh-keygen -lf /data/ssh/ssh_host_ed25519_key.pub
docker compose exec hugo /bin/cat /data/ssh/ssh_host_ed25519_key.pub
```

Create a CI `known_hosts` entry using that public key with the hostname prefix
`[your-server.example.com]:2222`. With the private key and known-hosts file
provisioned in CI, run:

```sh
ssh -i /path/to/ci-private-key \
  -o BatchMode=yes \
  -o IdentitiesOnly=yes \
  -o StrictHostKeyChecking=yes \
  -o UserKnownHostsFile=/path/to/ci-known-hosts \
  -p 2222 deploy@your-server.example.com 'git pull'
```

Trigger that job only after changes reach `main` (or your configured branch).
The literal command `deploy` is also accepted; other commands, shell access,
passwords, port forwarding, and root SSH logins are disabled. Concurrent deploys
are serialized. Deploys use `git pull --ff-only`; force-pushed/divergent history
requires manual repair. The worktree is not for manual edits. Changing the
configured branch on an existing volume may also require manual checkout setup.

## Build assumptions

The repository root is the Hugo project. Hugo is pinned to **0.169.0**, built
from source with the `extended,withdeploy` tags to match the working host.
A separate build stage uses Go 1.27 and Alpine 3.22; compilers and Go are not
included in the runtime image. The first image build can take several minutes.
The extended build supports LibSass, and Git submodules are initialized for
themes. Node/npm, Dart Sass, and other theme-specific dependencies are not
installed; add these if your site requires them.
To change Hugo versions, set the Docker build argument `HUGO_VERSION`.
Only generated output is served; the source repository and `.git` are outside
the web root. Hugo builds execute as `deploy`, not root. Deploy only trusted
site code: Hugo builds are not a sandbox for untrusted repositories.

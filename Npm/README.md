# Talk integrations skill

Help your coding agent integrate [Talk.swift](https://github.com/AppitStudio/Talk.swift) into macOS apps: typed contracts, provider and consumer wiring, discoverable pairing, scoped consent, live events, and signed-app validation.

From your app project's root, run:

```sh
npx talk-integrations@latest install
```

Requires Node.js 20+. Installs the complete skill for **Codex** in `.agents/skills/talk-integrations` and **Claude Code** in `.claude/skills/talk-integrations`.

Start a new agent session, then use `$talk-integrations` in Codex or `/talk-integrations` in Claude Code. Describe the apps and behavior you want:

```text
Add a Talk integration between my workspace app and focus app. Expose reading
and selecting scenes. Starting a focus session should select the Focus scene.
Add Start Pairing, Discover, Connect, full-code comparison and scoped consent.
Validate saved reconnect, cancellation, restart and revocation in the signed apps.
```

Supply your app projects and a Talk.swift checkout or resolved package source. The skill targets SDK `0.1.0-beta.2`; the npm version is independent. It installs instructions, references, starter code and a validation helper. Add the Swift SDK through Xcode or SwiftPM as described in the [installation guide](https://github.com/AppitStudio/Talk.swift/blob/main/Docs/INSTALLATION.md).

## Installation options

```sh
# Only one agent, in this project
npx talk-integrations@latest install --agent claude
npx talk-integrations@latest install --agent codex

# Both agents, for all your projects
npx talk-integrations@latest install --global

# Another agent that supports SKILL.md directories
npx talk-integrations@latest install --dir path/to/agent/skills
```

Global installs use `~/.agents/skills` and `~/.claude/skills`. The installer has no runtime dependencies, lifecycle install scripts or network calls. Existing skill directories and symlinks are preserved: to update, move your old `talk-integrations` directory aside, rerun the command, then reapply any local customizations. Remove the installed directory to uninstall. If migrating an older Codex copy from `~/.codex/skills`, move that copy aside too to avoid duplicate discovery.

These locations follow the [Codex skill documentation](https://developers.openai.com/codex/skills/) and [Claude Code skill documentation](https://code.claude.com/docs/en/skills). Agents with different policies or installation formats may need manual setup.

Talk is beta software. A successful build does not establish production readiness; validate your actual signed apps with synthetic or noncritical data. See the [integration guide](https://github.com/AppitStudio/Talk.swift/blob/main/Docs/LLM-INTEGRATION.md) and [qualification limits](https://github.com/AppitStudio/Talk.swift/blob/main/Docs/BETA-READINESS.md).

## License

This npm package, including the skill, starter assets and installer, is MIT licensed. The separately distributed Talk.swift SDK is also covered by the repository's [MIT License](https://github.com/AppitStudio/Talk.swift/blob/main/LICENSE).

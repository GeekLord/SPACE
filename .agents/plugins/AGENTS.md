# SPACE agent plugins

Plugin source lives under `.agents/plugins/<plugin>/`. Use this cross-agent layout:

```text
<plugin>/
├── plugin.yaml
├── skills/<skill>/SKILL.md
├── .claude-plugin/plugin.json
└── .codex-plugin/plugin.json
```

When adding or changing plugin content:

1. Keep `plugin.yaml`, `.claude-plugin/plugin.json`, and
   `.codex-plugin/plugin.json` identity, version, and description aligned.
2. Bump the plugin version in all three files when shipped content changes.
3. Update the repository marketplace entries when adding or renaming a plugin.
4. Run the applicable skill and plugin validators.

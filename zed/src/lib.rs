use zed_extension_api::settings::LspSettings;
use zed_extension_api::{self as zed, Result};

struct AmlExtension;

impl zed::Extension for AmlExtension {
    fn new() -> Self {
        Self
    }

    fn language_server_command(
        &mut self,
        language_server_id: &zed::LanguageServerId,
        worktree: &zed::Worktree,
    ) -> Result<zed::Command> {
        let settings = LspSettings::for_worktree(language_server_id.as_ref(), worktree)?;
        let command = settings
            .binary
            .as_ref()
            .and_then(|binary| binary.path.clone())
            .or_else(|| worktree.which("amlc-lsp"))
            .ok_or_else(|| "amlc-lsp was not found; configure lsp.amlc-lsp.binary.path or follow https://github.com/arkenstone-lab/amlc-lsp#install-the-server".to_string())?;
        let args = settings
            .binary
            .as_ref()
            .and_then(|binary| binary.arguments.clone())
            .unwrap_or_default();
        let env = settings
            .binary
            .and_then(|binary| binary.env)
            .unwrap_or_default()
            .into_iter()
            .collect();

        Ok(zed::Command { command, args, env })
    }
}

zed::register_extension!(AmlExtension);

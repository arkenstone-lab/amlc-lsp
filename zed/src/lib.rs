use std::fs;

use zed_extension_api::settings::LspSettings;
use zed_extension_api::{self as zed, Result};

const GITHUB_REPOSITORY: &str = "arkenstone-lab/amlc-lsp";
const SERVER_VERSION: &str = "0.3.0";

struct AmlExtension {
    cached_server_path: Option<String>,
}

struct AssetSpec {
    name: String,
    directory: String,
    executable: String,
    file_type: zed::DownloadedFileType,
}

fn asset_spec(os: zed::Os, architecture: zed::Architecture) -> Result<AssetSpec> {
    let target = match (os, architecture) {
        (zed::Os::Mac, zed::Architecture::Aarch64) => "aarch64-apple-darwin",
        (zed::Os::Mac, zed::Architecture::X8664) => "x86_64-apple-darwin",
        (zed::Os::Linux, zed::Architecture::Aarch64) => "aarch64-unknown-linux-gnu",
        (zed::Os::Linux, zed::Architecture::X8664) => "x86_64-unknown-linux-gnu",
        (zed::Os::Windows, zed::Architecture::X8664) => "x86_64-pc-windows-gnu",
        _ => return Err("amlc-lsp does not publish a server for this platform".into()),
    };
    let extension = if os == zed::Os::Windows {
        "zip"
    } else {
        "tar.gz"
    };
    let directory = format!("amlc-lsp-v{SERVER_VERSION}-{target}");

    Ok(AssetSpec {
        name: format!("{directory}.{extension}"),
        executable: format!(
            "{directory}/amlc-lsp{}",
            if os == zed::Os::Windows { ".exe" } else { "" }
        ),
        directory,
        file_type: if os == zed::Os::Windows {
            zed::DownloadedFileType::Zip
        } else {
            zed::DownloadedFileType::GzipTar
        },
    })
}

fn existing_server(configured: Option<String>, installed: Option<String>) -> Option<String> {
    configured.or(installed)
}

impl AmlExtension {
    fn bundled_server_path(
        &mut self,
        language_server_id: &zed::LanguageServerId,
    ) -> Result<String> {
        if let Some(path) = self
            .cached_server_path
            .as_ref()
            .filter(|path| fs::metadata(path).is_ok_and(|metadata| metadata.is_file()))
        {
            return Ok(path.clone());
        }

        let (os, architecture) = zed::current_platform();
        let spec = asset_spec(os, architecture)?;
        if !fs::metadata(&spec.executable).is_ok_and(|metadata| metadata.is_file()) {
            zed::set_language_server_installation_status(
                language_server_id,
                &zed::LanguageServerInstallationStatus::CheckingForUpdate,
            );
            let release =
                zed::github_release_by_tag_name(GITHUB_REPOSITORY, &format!("v{SERVER_VERSION}"))?;
            let asset = release
                .assets
                .into_iter()
                .find(|asset| asset.name == spec.name)
                .ok_or_else(|| format!("release v{SERVER_VERSION} has no {} asset", spec.name))?;

            zed::set_language_server_installation_status(
                language_server_id,
                &zed::LanguageServerInstallationStatus::Downloading,
            );
            if fs::metadata(&spec.directory).is_ok() {
                fs::remove_dir_all(&spec.directory)
                    .map_err(|error| format!("failed to replace bundled amlc-lsp: {error}"))?;
            }
            zed::download_file(&asset.download_url, &spec.directory, spec.file_type)
                .map_err(|error| format!("failed to download {}: {error}", spec.name))?;
            zed::make_file_executable(&spec.executable)
                .map_err(|error| format!("failed to make amlc-lsp executable: {error}"))?;
        }

        self.cached_server_path = Some(spec.executable.clone());
        Ok(spec.executable)
    }
}

impl zed::Extension for AmlExtension {
    fn new() -> Self {
        Self {
            cached_server_path: None,
        }
    }

    fn language_server_command(
        &mut self,
        language_server_id: &zed::LanguageServerId,
        worktree: &zed::Worktree,
    ) -> Result<zed::Command> {
        let settings = LspSettings::for_worktree(language_server_id.as_ref(), worktree)?;
        let configured = settings
            .binary
            .as_ref()
            .and_then(|binary| binary.path.clone());
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
        let command = match existing_server(configured, worktree.which("amlc-lsp")) {
            Some(command) => command,
            None => self.bundled_server_path(language_server_id)?,
        };

        Ok(zed::Command { command, args, env })
    }
}

zed::register_extension!(AmlExtension);

#[cfg(test)]
mod tests {
    use super::{asset_spec, existing_server};
    use zed_extension_api::{Architecture, DownloadedFileType, Os};

    #[test]
    fn prefers_an_explicit_server() {
        assert_eq!(
            existing_server(
                Some("/configured/amlc-lsp".into()),
                Some("/path/amlc-lsp".into())
            ),
            Some("/configured/amlc-lsp".into())
        );
    }

    #[test]
    fn uses_a_server_from_path() {
        assert_eq!(
            existing_server(None, Some("/path/amlc-lsp".into())),
            Some("/path/amlc-lsp".into())
        );
    }

    #[test]
    fn selects_unix_archives() {
        let mac = asset_spec(Os::Mac, Architecture::Aarch64).unwrap();
        assert_eq!(mac.name, "amlc-lsp-v0.3.0-aarch64-apple-darwin.tar.gz");
        assert_eq!(
            mac.executable,
            "amlc-lsp-v0.3.0-aarch64-apple-darwin/amlc-lsp"
        );
        assert!(matches!(mac.file_type, DownloadedFileType::GzipTar));

        let linux = asset_spec(Os::Linux, Architecture::X8664).unwrap();
        assert_eq!(
            linux.name,
            "amlc-lsp-v0.3.0-x86_64-unknown-linux-gnu.tar.gz"
        );
    }

    #[test]
    fn selects_a_windows_zip() {
        let windows = asset_spec(Os::Windows, Architecture::X8664).unwrap();
        assert_eq!(windows.name, "amlc-lsp-v0.3.0-x86_64-pc-windows-gnu.zip");
        assert!(windows.executable.ends_with("/amlc-lsp.exe"));
        assert!(matches!(windows.file_type, DownloadedFileType::Zip));
    }

    #[test]
    fn rejects_unsupported_x86() {
        assert!(asset_spec(Os::Linux, Architecture::X86).is_err());
    }
}

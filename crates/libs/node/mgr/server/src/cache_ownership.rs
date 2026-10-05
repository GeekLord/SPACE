//! Read-only retained-cache ownership verification shared by cleanup and reset.
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};

pub(crate) fn first_path_owned_by_uid(path: &Path, uid: u32) -> Result<Option<PathBuf>, String> {
    let mut stack = vec![path.to_path_buf()];
    while let Some(path) = stack.pop() {
        let metadata = match std::fs::symlink_metadata(&path) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
            Err(error) => return Err(format!("failed to stat {}: {error}", path.display())),
        };
        if metadata.uid() == uid || metadata.gid() == uid {
            return Ok(Some(path));
        }
        if metadata.is_dir() {
            let entries = std::fs::read_dir(&path)
                .map_err(|error| format!("failed to read {}: {error}", path.display()))?;
            for entry in entries {
                let entry = entry.map_err(|error| {
                    format!("failed to read entry in {}: {error}", path.display())
                })?;
                stack.push(entry.path());
            }
        }
    }
    Ok(None)
}

use thiserror::Error;

#[derive(Debug, Error)]
pub enum Error {
    #[error("database: {0}")]
    Db(#[from] rusqlite::Error),
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("imap: {0}")]
    Imap(String),
    #[error("tls: {0}")]
    Tls(String),
    #[error("auth: {0}")]
    Auth(String),
    #[error("secrets: {0}")]
    Secrets(String),
    #[error("parse: {0}")]
    Parse(String),
    #[error("not found: {0}")]
    NotFound(String),
    #[error("{0}")]
    Other(String),
}

pub type Result<T> = std::result::Result<T, Error>;

impl From<async_imap::error::Error> for Error {
    fn from(e: async_imap::error::Error) -> Self {
        match e {
            // The connection itself failed (reset, stalled): keep it an I/O error so a sync
            // stops using the dead session instead of failing folder after folder.
            async_imap::error::Error::Io(io) => Error::Io(io),
            // A clean close (BYE, then close_notify) is still a dead connection.
            async_imap::error::Error::ConnectionLost => Error::Io(std::io::Error::new(
                std::io::ErrorKind::ConnectionAborted,
                "the server closed the connection",
            )),
            // Parse errors quote what the server sent, message text included: keep the
            // start, enough to tell what failed.
            other => {
                let text = other.to_string();
                match text.char_indices().nth(300) {
                    Some((cut, _)) => Error::Imap(format!("{}…", &text[..cut])),
                    None => Error::Imap(text),
                }
            }
        }
    }
}
impl From<serde_json::Error> for Error {
    fn from(e: serde_json::Error) -> Self {
        Error::Parse(e.to_string())
    }
}

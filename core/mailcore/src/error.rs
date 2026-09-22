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
        Error::Imap(e.to_string())
    }
}
impl From<serde_json::Error> for Error {
    fn from(e: serde_json::Error) -> Self {
        Error::Parse(e.to_string())
    }
}

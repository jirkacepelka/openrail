//! Framing: every message is a little-endian `u32` byte length followed by
//! that many bytes of postcard.

use serde::{de::DeserializeOwned, Serialize};

/// Largest frame a host accepts from a client. Commands are tiny; this only
/// stops a peer from making us allocate a lot of memory.
pub const MAX_CLIENT_FRAME: usize = 64 * 1024;
/// Largest frame a client accepts from a host (world snapshots are big).
pub const MAX_SERVER_FRAME: usize = 256 * 1024 * 1024;

#[derive(Debug)]
pub enum CodecError {
    TooLarge { len: usize, max: usize },
    Decode(postcard::Error),
}

impl std::fmt::Display for CodecError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CodecError::TooLarge { len, max } => {
                write!(f, "frame of {len} bytes exceeds limit of {max}")
            }
            CodecError::Decode(e) => write!(f, "malformed message: {e}"),
        }
    }
}

impl std::error::Error for CodecError {}

/// Serializes a message into a complete frame, length prefix included.
pub fn encode<T: Serialize>(msg: &T) -> Vec<u8> {
    let mut frame =
        postcard::to_extend(msg, vec![0u8; 4]).expect("serializing into a Vec cannot fail");
    let len = u32::try_from(frame.len() - 4).expect("message larger than 4 GiB");
    frame[..4].copy_from_slice(&len.to_le_bytes());
    frame
}

/// Deserializes a frame payload (without its length prefix).
pub fn decode<T: DeserializeOwned>(payload: &[u8]) -> Result<T, CodecError> {
    postcard::from_bytes(payload).map_err(CodecError::Decode)
}

/// Incremental frame splitter for byte streams that arrive in arbitrary
/// chunks.
#[derive(Debug)]
pub struct FrameDecoder {
    buf: Vec<u8>,
    max: usize,
}

impl FrameDecoder {
    pub fn new(max_frame: usize) -> Self {
        FrameDecoder {
            buf: Vec::new(),
            max: max_frame,
        }
    }

    pub fn push(&mut self, bytes: &[u8]) {
        self.buf.extend_from_slice(bytes);
    }

    /// The next complete frame payload, if one has fully arrived.
    pub fn next_frame(&mut self) -> Result<Option<Vec<u8>>, CodecError> {
        if self.buf.len() < 4 {
            return Ok(None);
        }
        let len = u32::from_le_bytes(self.buf[..4].try_into().unwrap()) as usize;
        if len > self.max {
            return Err(CodecError::TooLarge { len, max: self.max });
        }
        if self.buf.len() < 4 + len {
            return Ok(None);
        }
        let payload = self.buf[4..4 + len].to_vec();
        self.buf.drain(..4 + len);
        Ok(Some(payload))
    }
}

#[cfg(feature = "quic")]
mod io {
    use super::*;
    use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

    /// Reads one frame payload. `Ok(None)` means the stream ended cleanly
    /// between frames.
    pub async fn read_frame<R: AsyncRead + Unpin>(
        r: &mut R,
        max: usize,
    ) -> std::io::Result<Option<Vec<u8>>> {
        let mut len = [0u8; 4];
        match r.read_exact(&mut len).await {
            Ok(_) => {}
            Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => return Ok(None),
            Err(e) => return Err(e),
        }
        let len = u32::from_le_bytes(len) as usize;
        if len > max {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                CodecError::TooLarge { len, max },
            ));
        }
        let mut payload = vec![0u8; len];
        r.read_exact(&mut payload).await?;
        Ok(Some(payload))
    }

    /// Writes a frame produced by [`encode`].
    pub async fn write_frame<W: AsyncWrite + Unpin>(
        w: &mut W,
        frame: &[u8],
    ) -> std::io::Result<()> {
        w.write_all(frame).await
    }
}

#[cfg(feature = "quic")]
pub use io::{read_frame, write_frame};

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::{ClientMsg, ServerMsg, TickBundle};
    use openrail_sim::{Command, Fixed, PlayerId, Vec2};

    #[test]
    fn roundtrip_through_chunked_decoder() {
        let msgs = vec![
            ServerMsg::Tick(TickBundle {
                tick: 7,
                commands: vec![(
                    PlayerId(3),
                    Command::BuildNode {
                        pos: Vec2::new(Fixed::from_int(1), Fixed::from_int(-2)),
                    },
                )],
                hash_check: Some((8, 0xdead_beef)),
            }),
            ServerMsg::Kick {
                reason: "bye".into(),
            },
        ];
        let bytes: Vec<u8> = msgs.iter().flat_map(encode).collect();
        let mut dec = FrameDecoder::new(MAX_SERVER_FRAME);
        let mut out = Vec::new();
        // Feed one byte at a time: the worst case for a stream.
        for b in bytes {
            dec.push(&[b]);
            while let Some(f) = dec.next_frame().unwrap() {
                out.push(decode::<ServerMsg>(&f).unwrap());
            }
        }
        assert_eq!(out, msgs);
    }

    #[test]
    fn oversized_frame_is_rejected() {
        let frame = encode(&ClientMsg::Chat {
            text: "x".repeat(100),
        });
        let mut dec = FrameDecoder::new(10);
        dec.push(&frame);
        assert!(matches!(
            dec.next_frame(),
            Err(CodecError::TooLarge { max: 10, .. })
        ));
    }

    #[test]
    fn garbage_fails_to_decode() {
        assert!(decode::<ClientMsg>(&[0xff, 0xff, 0xff]).is_err());
    }
}

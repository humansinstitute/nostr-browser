use secp256k1::{Keypair, Secp256k1};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use thiserror::Error;

use super::DeviceKey;

#[derive(Debug, Error)]
pub enum NostrEventError {
    #[error("invalid event: {0}")]
    InvalidEvent(String),
    #[error("signing failed: {0}")]
    Signing(String),
    #[error("serialization failed: {0}")]
    Serialization(String),
}

#[derive(Debug, Clone, Deserialize)]
pub struct UnsignedNostrEvent {
    pub kind: u64,
    #[serde(default)]
    pub tags: Vec<Vec<String>>,
    #[serde(default)]
    pub content: String,
    pub created_at: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SignedNostrEvent {
    pub id: String,
    pub pubkey: String,
    pub created_at: u64,
    pub kind: u64,
    pub tags: Vec<Vec<String>>,
    pub content: String,
    pub sig: String,
}

pub struct NostrEventSigner {
    key: DeviceKey,
}

impl NostrEventSigner {
    pub fn new(key: DeviceKey) -> Self {
        Self { key }
    }

    pub fn sign(&self, event: UnsignedNostrEvent) -> Result<SignedNostrEvent, NostrEventError> {
        let pubkey = self.key.public_key_hex();
        let created_at = event.created_at.unwrap_or_else(current_unix_timestamp);
        let event_id = event_id(&pubkey, created_at, event.kind, &event.tags, &event.content)?;
        let sig = sign_event_id(self.key.secret_key(), &event_id)?;

        Ok(SignedNostrEvent {
            id: event_id,
            pubkey,
            created_at,
            kind: event.kind,
            tags: event.tags,
            content: event.content,
            sig,
        })
    }
}

fn current_unix_timestamp() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

fn event_id(
    pubkey: &str,
    created_at: u64,
    kind: u64,
    tags: &[Vec<String>],
    content: &str,
) -> Result<String, NostrEventError> {
    let serialized = serde_json::json!([0, pubkey, created_at, kind, tags, content]);
    let bytes = serde_json::to_vec(&serialized)
        .map_err(|error| NostrEventError::Serialization(error.to_string()))?;
    Ok(hex::encode(Sha256::digest(bytes)))
}

fn sign_event_id(
    secret_key: &secp256k1::SecretKey,
    event_id: &str,
) -> Result<String, NostrEventError> {
    let secp = Secp256k1::new();
    let keypair = Keypair::from_secret_key(&secp, secret_key);
    let event_id_bytes =
        hex::decode(event_id).map_err(|error| NostrEventError::Signing(error.to_string()))?;
    let digest: [u8; 32] = event_id_bytes
        .try_into()
        .map_err(|_| NostrEventError::Signing("event id must be 32 bytes".to_string()))?;
    let signature = secp.sign_schnorr_no_aux_rand(&digest, &keypair);
    Ok(signature.to_string())
}

#[cfg(test)]
mod tests {
    use secp256k1::schnorr::Signature;
    use secp256k1::XOnlyPublicKey;

    use super::*;

    #[test]
    fn signs_nip07_event_template() {
        let key =
            DeviceKey::from_hex("0000000000000000000000000000000000000000000000000000000000000001")
                .unwrap();
        let event = NostrEventSigner::new(key)
            .sign(UnsignedNostrEvent {
                kind: 1,
                tags: vec![vec!["client".to_string(), "wingman".to_string()]],
                content: "hello".to_string(),
                created_at: Some(1_700_000_000),
            })
            .unwrap();

        assert_eq!(event.kind, 1);
        assert_eq!(event.content, "hello");
        assert_eq!(event.created_at, 1_700_000_000);
        verify_event_signature(&event);
    }

    fn verify_event_signature(event: &SignedNostrEvent) {
        let secp = Secp256k1::new();
        let public_key_bytes: [u8; 32] = hex::decode(&event.pubkey).unwrap().try_into().unwrap();
        let public_key = XOnlyPublicKey::from_byte_array(public_key_bytes).unwrap();
        let event_id_bytes: [u8; 32] = hex::decode(&event.id).unwrap().try_into().unwrap();
        let signature = event.sig.parse::<Signature>().unwrap();
        secp.verify_schnorr(&signature, &event_id_bytes, &public_key)
            .unwrap();
    }
}

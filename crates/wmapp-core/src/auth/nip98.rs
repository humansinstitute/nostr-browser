use base64::{engine::general_purpose::STANDARD, Engine as _};
use secp256k1::{Keypair, Secp256k1};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use thiserror::Error;
use url::Url;

use super::DeviceKey;

pub const NIP98_KIND: u64 = 27_235;

#[derive(Debug, Error)]
pub enum Nip98Error {
    #[error("invalid url: {0}")]
    InvalidUrl(String),
    #[error("invalid method: {0}")]
    InvalidMethod(String),
    #[error("signing failed: {0}")]
    Signing(String),
    #[error("serialization failed: {0}")]
    Serialization(String),
}

#[derive(Debug, Clone)]
pub struct Nip98Request {
    pub method: String,
    pub url: Url,
    pub body: Option<Vec<u8>>,
    pub created_at: u64,
}

impl Nip98Request {
    pub fn new(method: impl Into<String>, url: impl AsRef<str>) -> Result<Self, Nip98Error> {
        let method = normalize_method(method.into())?;
        let url =
            Url::parse(url.as_ref()).map_err(|error| Nip98Error::InvalidUrl(error.to_string()))?;
        Ok(Self {
            method,
            url,
            body: None,
            created_at: current_unix_timestamp(),
        })
    }

    pub fn with_body(mut self, body: impl Into<Vec<u8>>) -> Self {
        let body = body.into();
        if body.is_empty() {
            self.body = None;
        } else {
            self.body = Some(body);
        }
        self
    }

    pub fn at(mut self, created_at: u64) -> Self {
        self.created_at = created_at;
        self
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SignedNip98Event {
    pub id: String,
    pub pubkey: String,
    pub created_at: u64,
    pub kind: u64,
    pub tags: Vec<Vec<String>>,
    pub content: String,
    pub sig: String,
}

impl SignedNip98Event {
    pub fn authorization_header(&self) -> Result<String, Nip98Error> {
        let json = serde_json::to_vec(self)
            .map_err(|error| Nip98Error::Serialization(error.to_string()))?;
        Ok(format!("Nostr {}", STANDARD.encode(json)))
    }

    pub fn payload_hash(&self) -> Option<&str> {
        self.tags
            .iter()
            .find(|tag| tag.first().map(String::as_str) == Some("payload"))
            .and_then(|tag| tag.get(1))
            .map(String::as_str)
    }
}

pub struct Nip98Signer {
    key: DeviceKey,
}

impl Nip98Signer {
    pub fn new(key: DeviceKey) -> Self {
        Self { key }
    }

    pub fn public_key_hex(&self) -> String {
        self.key.public_key_hex()
    }

    pub fn sign(&self, request: Nip98Request) -> Result<SignedNip98Event, Nip98Error> {
        let mut tags = vec![
            vec!["u".to_string(), request.url.to_string()],
            vec!["method".to_string(), request.method],
        ];
        if let Some(body) = request.body {
            tags.push(vec!["payload".to_string(), sha256_hex(&body)]);
        }

        let pubkey = self.key.public_key_hex();
        let content = String::new();
        let event_id = event_id(&pubkey, request.created_at, &tags, &content)?;
        let sig = sign_event_id(self.key.secret_key(), &event_id)?;

        Ok(SignedNip98Event {
            id: event_id,
            pubkey,
            created_at: request.created_at,
            kind: NIP98_KIND,
            tags,
            content,
            sig,
        })
    }
}

fn normalize_method(method: String) -> Result<String, Nip98Error> {
    let normalized = method.trim().to_uppercase();
    if normalized.is_empty()
        || !normalized
            .chars()
            .all(|character| character.is_ascii_uppercase() || character == '-')
    {
        return Err(Nip98Error::InvalidMethod(method));
    }
    Ok(normalized)
}

fn current_unix_timestamp() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

fn sha256_hex(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}

fn event_id(
    pubkey: &str,
    created_at: u64,
    tags: &[Vec<String>],
    content: &str,
) -> Result<String, Nip98Error> {
    let serialized = serde_json::json!([0, pubkey, created_at, NIP98_KIND, tags, content]);
    let bytes = serde_json::to_vec(&serialized)
        .map_err(|error| Nip98Error::Serialization(error.to_string()))?;
    Ok(sha256_hex(&bytes))
}

fn sign_event_id(secret_key: &secp256k1::SecretKey, event_id: &str) -> Result<String, Nip98Error> {
    let secp = Secp256k1::new();
    let keypair = Keypair::from_secret_key(&secp, secret_key);
    let event_id_bytes =
        hex::decode(event_id).map_err(|error| Nip98Error::Signing(error.to_string()))?;
    let digest: [u8; 32] = event_id_bytes
        .try_into()
        .map_err(|_| Nip98Error::Signing("event id must be 32 bytes".to_string()))?;
    let signature = secp.sign_schnorr_no_aux_rand(&digest, &keypair);
    Ok(signature.to_string())
}

#[cfg(test)]
mod tests {
    use secp256k1::schnorr::Signature;
    use secp256k1::XOnlyPublicKey;

    use super::*;

    #[test]
    fn signs_get_request_without_payload_hash() {
        let key =
            DeviceKey::from_hex("0000000000000000000000000000000000000000000000000000000000000001")
                .unwrap();
        let event = Nip98Signer::new(key)
            .sign(
                Nip98Request::new("get", "https://tower.example/api")
                    .unwrap()
                    .at(1_700_000_000),
            )
            .unwrap();

        assert_eq!(event.kind, NIP98_KIND);
        assert_eq!(event.tags[0], vec!["u", "https://tower.example/api"]);
        assert_eq!(event.tags[1], vec!["method", "GET"]);
        assert!(event.payload_hash().is_none());
        verify_event_signature(&event);
    }

    #[test]
    fn signs_post_request_with_payload_hash() {
        let key =
            DeviceKey::from_hex("0000000000000000000000000000000000000000000000000000000000000001")
                .unwrap();
        let body = br#"{"hello":"wingman"}"#;
        let event = Nip98Signer::new(key)
            .sign(
                Nip98Request::new("POST", "https://tower.example/api")
                    .unwrap()
                    .with_body(body.to_vec())
                    .at(1_700_000_000),
            )
            .unwrap();

        assert_eq!(event.payload_hash(), Some(sha256_hex(body).as_str()));
        verify_event_signature(&event);
    }

    #[test]
    fn authorization_header_is_nostr_base64_json() {
        let key =
            DeviceKey::from_hex("0000000000000000000000000000000000000000000000000000000000000001")
                .unwrap();
        let event = Nip98Signer::new(key)
            .sign(
                Nip98Request::new("GET", "https://tower.example/api")
                    .unwrap()
                    .at(1_700_000_000),
            )
            .unwrap();
        let header = event.authorization_header().unwrap();
        assert!(header.starts_with("Nostr "));
    }

    fn verify_event_signature(event: &SignedNip98Event) {
        let secp = Secp256k1::new();
        let public_key_bytes: [u8; 32] = hex::decode(&event.pubkey).unwrap().try_into().unwrap();
        let public_key = XOnlyPublicKey::from_byte_array(public_key_bytes).unwrap();
        let event_id_bytes: [u8; 32] = hex::decode(&event.id).unwrap().try_into().unwrap();
        let signature = event.sig.parse::<Signature>().unwrap();
        secp.verify_schnorr(&signature, &event_id_bytes, &public_key)
            .unwrap();
    }
}

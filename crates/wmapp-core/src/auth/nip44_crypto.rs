use bech32::FromBase32;
use secp256k1::{SecretKey, XOnlyPublicKey};
use thiserror::Error;

use super::DeviceKey;

#[derive(Debug, Error)]
pub enum Nip44CryptoError {
    #[error("invalid peer public key: {0}")]
    InvalidPeerPublicKey(String),
    #[error("NIP-44 failed: {0}")]
    Nip44(String),
}

pub struct Nip44Crypto {
    key: DeviceKey,
}

impl Nip44Crypto {
    pub fn new(key: DeviceKey) -> Self {
        Self { key }
    }

    pub fn encrypt(
        &self,
        peer_public_key: &str,
        plaintext: &str,
    ) -> Result<String, Nip44CryptoError> {
        let peer = parse_xonly_public_key(peer_public_key)?;
        let conversation_key = nip44::get_conversation_key(self.secret_key(), peer);
        nip44::encrypt(&conversation_key, plaintext)
            .map_err(|error| Nip44CryptoError::Nip44(error.to_string()))
    }

    pub fn decrypt(
        &self,
        peer_public_key: &str,
        ciphertext: &str,
    ) -> Result<String, Nip44CryptoError> {
        let peer = parse_xonly_public_key(peer_public_key)?;
        let conversation_key = nip44::get_conversation_key(self.secret_key(), peer);
        nip44::decrypt(&conversation_key, ciphertext)
            .map_err(|error| Nip44CryptoError::Nip44(error.to_string()))
    }

    fn secret_key(&self) -> SecretKey {
        SecretKey::from_byte_array(self.key.secret_key().secret_bytes())
            .expect("DeviceKey always contains a valid secp256k1 secret key")
    }
}

fn parse_xonly_public_key(value: &str) -> Result<XOnlyPublicKey, Nip44CryptoError> {
    let trimmed = value.trim();
    let bytes = if trimmed.starts_with("npub1") {
        let (hrp, data, _variant) = bech32::decode(trimmed)
            .map_err(|error| Nip44CryptoError::InvalidPeerPublicKey(error.to_string()))?;
        if hrp != "npub" {
            return Err(Nip44CryptoError::InvalidPeerPublicKey(
                "expected npub bech32 public key".to_string(),
            ));
        }
        Vec::<u8>::from_base32(&data)
            .map_err(|error| Nip44CryptoError::InvalidPeerPublicKey(error.to_string()))?
    } else {
        hex::decode(trimmed)
            .map_err(|error| Nip44CryptoError::InvalidPeerPublicKey(error.to_string()))?
    };
    let bytes: [u8; 32] = bytes
        .try_into()
        .map_err(|_| Nip44CryptoError::InvalidPeerPublicKey("expected 32 bytes".to_string()))?;
    XOnlyPublicKey::from_byte_array(bytes)
        .map_err(|error| Nip44CryptoError::InvalidPeerPublicKey(error.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encrypts_and_decrypts_between_two_keys() {
        let alice =
            DeviceKey::from_hex("0000000000000000000000000000000000000000000000000000000000000001")
                .unwrap();
        let bob =
            DeviceKey::from_hex("0000000000000000000000000000000000000000000000000000000000000002")
                .unwrap();

        let ciphertext = Nip44Crypto::new(alice.clone())
            .encrypt(&bob.public_key_hex(), "hello flight deck")
            .unwrap();
        let plaintext = Nip44Crypto::new(bob)
            .decrypt(&alice.public_key_hex(), &ciphertext)
            .unwrap();

        assert_eq!(plaintext, "hello flight deck");
    }

    #[test]
    fn accepts_npub_peer_keys() {
        let alice =
            DeviceKey::from_hex("0000000000000000000000000000000000000000000000000000000000000001")
                .unwrap();
        let bob =
            DeviceKey::from_hex("0000000000000000000000000000000000000000000000000000000000000002")
                .unwrap();

        let ciphertext = Nip44Crypto::new(alice.clone())
            .encrypt(&bob.npub().unwrap(), "hello npub")
            .unwrap();
        let plaintext = Nip44Crypto::new(bob)
            .decrypt(&alice.npub().unwrap(), &ciphertext)
            .unwrap();

        assert_eq!(plaintext, "hello npub");
    }
}

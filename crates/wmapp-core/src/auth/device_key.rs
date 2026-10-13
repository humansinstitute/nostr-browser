use bech32::{FromBase32, ToBase32, Variant};
use rand::{rngs::OsRng, RngCore};
use secp256k1::{PublicKey, Secp256k1, SecretKey};
use thiserror::Error;

const NSEC_HRP: &str = "nsec";
const NPUB_HRP: &str = "npub";

#[derive(Debug, Error)]
pub enum DeviceKeyError {
    #[error("invalid secret key: {0}")]
    InvalidSecret(String),
    #[error("invalid bech32 key: {0}")]
    InvalidBech32(String),
    #[error("key store error: {0}")]
    Store(String),
}

#[derive(Clone)]
pub struct DeviceKey {
    secret_key: SecretKey,
}

impl DeviceKey {
    pub fn generate() -> Self {
        let mut rng = OsRng;
        loop {
            let mut bytes = [0_u8; 32];
            rng.fill_bytes(&mut bytes);
            if let Ok(secret_key) = SecretKey::from_byte_array(bytes) {
                return Self { secret_key };
            }
        }
    }

    pub fn from_hex(value: &str) -> Result<Self, DeviceKeyError> {
        let bytes = hex::decode(value.trim())
            .map_err(|error| DeviceKeyError::InvalidSecret(error.to_string()))?;
        let bytes: [u8; 32] = bytes.try_into().map_err(|_| {
            DeviceKeyError::InvalidSecret("secret key must be 32 bytes".to_string())
        })?;
        let secret_key = SecretKey::from_byte_array(bytes)
            .map_err(|error| DeviceKeyError::InvalidSecret(error.to_string()))?;
        Ok(Self { secret_key })
    }

    pub fn from_nsec(value: &str) -> Result<Self, DeviceKeyError> {
        let (hrp, data, variant) = bech32::decode(value.trim())
            .map_err(|error| DeviceKeyError::InvalidBech32(error.to_string()))?;
        if hrp != NSEC_HRP || variant != Variant::Bech32 {
            return Err(DeviceKeyError::InvalidBech32(
                "expected nsec bech32 secret key".to_string(),
            ));
        }
        let bytes = Vec::<u8>::from_base32(&data)
            .map_err(|error| DeviceKeyError::InvalidBech32(error.to_string()))?;
        let bytes: [u8; 32] = bytes.try_into().map_err(|_| {
            DeviceKeyError::InvalidSecret("secret key must be 32 bytes".to_string())
        })?;
        let secret_key = SecretKey::from_byte_array(bytes)
            .map_err(|error| DeviceKeyError::InvalidSecret(error.to_string()))?;
        Ok(Self { secret_key })
    }

    pub fn import(value: &str) -> Result<Self, DeviceKeyError> {
        let trimmed = value.trim();
        if trimmed.starts_with(NSEC_HRP) {
            Self::from_nsec(trimmed)
        } else {
            Self::from_hex(trimmed)
        }
    }

    pub fn secret_hex(&self) -> String {
        hex::encode(self.secret_key.secret_bytes())
    }

    pub fn nsec(&self) -> Result<String, DeviceKeyError> {
        bech32::encode(
            NSEC_HRP,
            self.secret_key.secret_bytes().to_base32(),
            Variant::Bech32,
        )
        .map_err(|error| DeviceKeyError::InvalidBech32(error.to_string()))
    }

    pub fn public_key_hex(&self) -> String {
        let secp = Secp256k1::new();
        let public_key = PublicKey::from_secret_key(&secp, &self.secret_key);
        let serialized = public_key.serialize();
        hex::encode(&serialized[1..])
    }

    pub fn npub(&self) -> Result<String, DeviceKeyError> {
        let secp = Secp256k1::new();
        let public_key = PublicKey::from_secret_key(&secp, &self.secret_key);
        let serialized = public_key.serialize();
        bech32::encode(NPUB_HRP, (&serialized[1..]).to_base32(), Variant::Bech32)
            .map_err(|error| DeviceKeyError::InvalidBech32(error.to_string()))
    }

    pub(crate) fn secret_key(&self) -> &SecretKey {
        &self.secret_key
    }
}

pub trait DeviceKeyStore {
    fn load(&self) -> Result<Option<DeviceKey>, DeviceKeyError>;
    fn save(&mut self, key: DeviceKey) -> Result<(), DeviceKeyError>;
    fn clear(&mut self) -> Result<(), DeviceKeyError>;
}

#[derive(Default)]
pub struct DevelopmentKeyStore {
    key: Option<DeviceKey>,
}

impl DevelopmentKeyStore {
    pub fn new() -> Self {
        Self::default()
    }
}

impl DeviceKeyStore for DevelopmentKeyStore {
    fn load(&self) -> Result<Option<DeviceKey>, DeviceKeyError> {
        Ok(self.key.clone())
    }

    fn save(&mut self, key: DeviceKey) -> Result<(), DeviceKeyError> {
        self.key = Some(key);
        Ok(())
    }

    fn clear(&mut self) -> Result<(), DeviceKeyError> {
        self.key = None;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generated_key_round_trips_through_nsec() {
        let key = DeviceKey::generate();
        let imported = DeviceKey::from_nsec(&key.nsec().unwrap()).unwrap();
        assert_eq!(key.secret_hex(), imported.secret_hex());
        assert_eq!(key.public_key_hex(), imported.public_key_hex());
        assert!(key.npub().unwrap().starts_with("npub1"));
    }

    #[test]
    fn development_store_saves_and_clears_key() {
        let key = DeviceKey::generate();
        let mut store = DevelopmentKeyStore::new();
        store.save(key.clone()).unwrap();
        assert_eq!(
            store.load().unwrap().unwrap().secret_hex(),
            key.secret_hex()
        );
        store.clear().unwrap();
        assert!(store.load().unwrap().is_none());
    }
}

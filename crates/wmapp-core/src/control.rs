#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CoreStatus {
    pub device_npub: Option<String>,
    pub tower_url: Option<String>,
}

#[derive(Debug, Default)]
pub struct ControlApi;

impl ControlApi {
    pub fn status(&self) -> CoreStatus {
        CoreStatus {
            device_npub: None,
            tower_url: None,
        }
    }
}

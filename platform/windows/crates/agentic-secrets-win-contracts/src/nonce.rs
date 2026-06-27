use std::collections::HashMap;
use thiserror::Error;
use time::{Duration, OffsetDateTime};

#[derive(Debug, Error, PartialEq, Eq)]
pub enum NonceReplayError {
    #[error("request timestamp is outside the allowed TTL")]
    Stale,
    #[error("nonce has already been used")]
    Replay,
}

#[derive(Debug, Clone)]
pub struct NonceReplayCache {
    ttl: Duration,
    seen: HashMap<String, OffsetDateTime>,
}

impl NonceReplayCache {
    pub fn new(ttl: Duration) -> Self {
        Self {
            ttl,
            seen: HashMap::new(),
        }
    }

    pub fn accept(
        &mut self,
        nonce: &str,
        timestamp: OffsetDateTime,
        now: OffsetDateTime,
    ) -> Result<(), NonceReplayError> {
        self.retain_live(now);
        if timestamp < now - self.ttl || timestamp > now + self.ttl {
            return Err(NonceReplayError::Stale);
        }
        if self.seen.contains_key(nonce) {
            return Err(NonceReplayError::Replay);
        }
        self.seen.insert(nonce.to_string(), timestamp);
        Ok(())
    }

    fn retain_live(&mut self, now: OffsetDateTime) {
        let ttl = self.ttl;
        self.seen
            .retain(|_, timestamp| *timestamp >= now - ttl && *timestamp <= now + ttl);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_replayed_and_stale_nonces() {
        let now = OffsetDateTime::from_unix_timestamp(1_700_000_000).expect("time");
        let mut cache = NonceReplayCache::new(Duration::seconds(30));

        cache.accept("n1", now, now).expect("first");
        assert_eq!(cache.accept("n1", now, now), Err(NonceReplayError::Replay));
        assert_eq!(
            cache.accept("n2", now - Duration::seconds(31), now),
            Err(NonceReplayError::Stale)
        );
    }
}

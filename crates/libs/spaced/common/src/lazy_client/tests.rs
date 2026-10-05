use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use super::*;

#[tokio::test]
async fn concurrent_connects_keep_first_cached_client() -> anyhow::Result<()> {
    let lazy = Arc::new(LazyClient::new());
    let barrier = Arc::new(tokio::sync::Barrier::new(2));
    let connect_count = Arc::new(AtomicUsize::new(0));

    let first = {
        let lazy = Arc::clone(&lazy);
        let barrier = Arc::clone(&barrier);
        let connect_count = Arc::clone(&connect_count);
        tokio::spawn(async move {
            lazy.get_or_connect::<anyhow::Error, _, _>(|| async move {
                let value = connect_count.fetch_add(1, Ordering::SeqCst) + 1;
                barrier.wait().await;
                Ok(value)
            })
            .await
        })
    };
    let second = {
        let lazy = Arc::clone(&lazy);
        let barrier = Arc::clone(&barrier);
        let connect_count = Arc::clone(&connect_count);
        tokio::spawn(async move {
            lazy.get_or_connect::<anyhow::Error, _, _>(|| async move {
                let value = connect_count.fetch_add(1, Ordering::SeqCst) + 1;
                barrier.wait().await;
                Ok(value)
            })
            .await
        })
    };

    let first = first.await??;
    let second = second.await??;
    assert_eq!(connect_count.load(Ordering::SeqCst), 2);
    assert_eq!(first, second);
    assert_eq!(
        lazy.get_or_connect::<anyhow::Error, _, _>(|| async { Ok(99) })
            .await?,
        first
    );
    Ok(())
}

#[tokio::test]
async fn clear_if_generation_does_not_clear_newer_client() -> anyhow::Result<()> {
    let lazy = LazyClient::new();
    let first = lazy
        .get_or_connect_with_generation::<anyhow::Error, _, _>(|| async { Ok(1) })
        .await?;
    let first_generation = first.generation();
    assert!(lazy.clear_if_generation(first_generation).await);

    let second = lazy
        .get_or_connect_with_generation::<anyhow::Error, _, _>(|| async { Ok(2) })
        .await?;
    assert_ne!(first_generation, second.generation());
    assert!(!lazy.clear_if_generation(first_generation).await);
    assert_eq!(
        lazy.get_or_connect::<anyhow::Error, _, _>(|| async { Ok(3) })
            .await?,
        2
    );
    Ok(())
}

use agentic_secrets_win_broker::{Broker, BrokerPolicy};
use agentic_secrets_win_contracts::DeliveryPlanRequest;
use anyhow::Context;
use clap::{Parser, Subcommand};
use std::collections::HashMap;
use std::fs;
use time::OffsetDateTime;

#[derive(Debug, Parser)]
#[command(name = "agentic-secrets-win-broker")]
#[command(about = "Windows per-user broker prototype")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Create a synthetic delivery plan from a JSON request file.
    Plan {
        #[arg(long)]
        request: String,
    },
}

fn main() -> anyhow::Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Command::Plan { request } => {
            let request: DeliveryPlanRequest = serde_json::from_slice(
                &fs::read(&request).with_context(|| format!("read request {request}"))?,
            )?;
            let parent = std::env::vars().collect::<HashMap<_, _>>();
            let mut broker = Broker::new(BrokerPolicy::synthetic_default());
            let plan = broker.create_delivery_plan(request, &parent, OffsetDateTime::now_utc())?;
            println!(
                "{}",
                serde_json::to_string_pretty(&plan.redacted_for_audit())?
            );
        }
    }
    Ok(())
}

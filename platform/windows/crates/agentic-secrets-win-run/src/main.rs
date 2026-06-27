use agentic_secrets_win_broker::{Broker, BrokerPolicy};
use agentic_secrets_win_contracts::{DeliveryPlan, DeliveryPlanRequest, RunnerIdentity};
use agentic_secrets_win_run::{
    build_child_environment, launch_plan, request_plan_from_broker, validate_delivery_plan,
};
use anyhow::{bail, Context};
use clap::Parser;
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::fs;
use time::OffsetDateTime;

#[derive(Debug, Parser)]
#[command(name = "agentic-secrets-win-run")]
#[command(about = "Windows command runner")]
struct Cli {
    #[arg(long)]
    profile: Option<String>,
    #[arg(long)]
    plan: Option<String>,
    #[arg(long)]
    broker_pipe: Option<String>,
    #[arg(long)]
    dry_run: bool,
    #[arg(long)]
    demo_synthetic_broker: bool,
    #[arg(last = true)]
    command: Vec<String>,
}

fn main() -> anyhow::Result<()> {
    let cli = Cli::parse();
    let plan = if let Some(plan_path) = cli.plan {
        serde_json::from_slice::<DeliveryPlan>(
            &fs::read(&plan_path).with_context(|| format!("read plan {plan_path}"))?,
        )?
    } else if let Some(broker_pipe) = &cli.broker_pipe {
        if cli.command.is_empty() {
            bail!("expected -- <command> when using --broker-pipe");
        }
        request_plan_from_broker(broker_pipe, delivery_plan_request(&cli)?)?
    } else if cli.demo_synthetic_broker {
        let profile = cli
            .profile
            .clone()
            .unwrap_or_else(|| "synthetic".to_string());
        if cli.command.is_empty() {
            bail!("expected -- <command> or --plan <path>");
        }
        let mut request = delivery_plan_request(&cli)?;
        request.profile = profile;
        let parent = std::env::vars().collect::<HashMap<_, _>>();
        let mut broker = Broker::new(BrokerPolicy::synthetic_default());
        broker.create_delivery_plan(request, &parent, OffsetDateTime::now_utc())?
    } else {
        bail!(
            "expected --plan <path> or --broker-pipe <path>; --demo-synthetic-broker is for local synthetic testing only"
        );
    };

    validate_delivery_plan(&plan, OffsetDateTime::now_utc())?;
    let parent = std::env::vars().collect::<HashMap<_, _>>();
    let child_environment = build_child_environment(&plan, &parent)?;
    if cli.dry_run {
        println!(
            "{}",
            serde_json::to_string_pretty(&plan.redacted_for_audit()).context("encode dry run")?
        );
        println!(
            "environmentKeys={:?}",
            child_environment.variables().keys().collect::<Vec<_>>()
        );
        return Ok(());
    }

    let code = launch_plan(&plan)?;
    std::process::exit(code);
}

fn delivery_plan_request(cli: &Cli) -> anyhow::Result<DeliveryPlanRequest> {
    let profile = cli
        .profile
        .clone()
        .unwrap_or_else(|| "synthetic".to_string());
    let target = cli.command[0].clone();
    let arguments = cli.command[1..].to_vec();
    Ok(DeliveryPlanRequest {
        profile,
        target_executable: target,
        arguments,
        workspace: std::env::current_dir()?.to_string_lossy().to_string(),
        action_class: "read-only".to_string(),
        origin_hint: "agentic-secrets-win-run".to_string(),
        parent_environment_keys: std::env::vars().map(|(key, _)| key).collect(),
        runner_identity: current_runner_identity(),
    })
}

fn current_runner_identity() -> RunnerIdentity {
    let executable_path = std::env::current_exe()
        .ok()
        .map(|path| path.to_string_lossy().to_string())
        .unwrap_or_default();
    let sha256 = fs::read(&executable_path)
        .map(|bytes| hex::encode(Sha256::digest(bytes)))
        .unwrap_or_default();
    RunnerIdentity {
        executable_path,
        sha256,
        process_id: Some(std::process::id()),
        user_sid: None,
    }
}

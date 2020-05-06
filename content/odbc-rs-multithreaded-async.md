+++
title = "Getting odbc-rs to work in threaded, async-land"
date = 2020-05-07 

[taxonomies]
tags = ["rust"]
+++

If you're one of the lucky people using Microsoft SQL Server as your backend database, you've no doubt discovered you're mostly alone in Rust.  For a while, there was Tiberius, which worked in some circumstances, but had a set of requirements that not all MSSQL users could match.  Notably, TCP had to be enabled in MSSQL and a valid SSL certificate was required on the server unless you chose to remove encryption for your ENTIRE crate.  Even if your project met those requirements, Tiberius is no longer maintained and [Rust-Sec has advised against its use](https://github.com/RustSec/advisory-db/issues/261).

That leaves exactly one option: [odbc-rs](https://github.com/Koka/odbc-rs). The crate is just an FFI binding, thus is not thread-safe (i.e. !Send).  This is pretty annoying for obvious reasons if you're attempting to use it from inside the major web crates.  This post focuses on Tokio, though presumably any other runtime will also have an equivalent means of forcing certain code onto a single thread.

<!-- more -->

For Tokio, you have to get the async executor to constrain odbc-rs to a single thread and have it communicate with the rest of your application using methods such as IPC channels.  This adds a bit of complexity and boilerplate, but does allow you to make use of a single environment/connection from multiple threads.

In the tokio ecosystem, you'd constrain it to a single thread with [tokio::task::LocalSet](https://docs.rs/tokio/0.2.18/tokio/task/struct.LocalSet.html), and use [tokio::sync::mpsc](https://docs.rs/tokio/0.2.18/tokio/sync/mpsc/fn.channel.html) (or any other async channels) to send data in and out.

```rs
pub enum SQLQueryChannelMsg {
    Query(String),
    Result(Vec<String>),
}

#[tokio::main]
async fn main() {
    // Dual channels for the query and result
    let (sendSQL, recvSQL) = mpsc::channel(5);
    let (sendQueryResults, recvQueryResults) = mpsc::channel(5);

    let rc = Arc::new(Mutex::new(recvQueryResults));

    // Spawn a tokio thread and run the web server there
    tokio::task::spawn(
        warp::serve(RoutesBuilder::build(sendSQL.clone(),rc.clone())
    ).run(([127, 0, 0, 1], 8000)));

    // Run the local task set for mssql queries that require !Send futures.
    // This is going to block the thread until the local task is done
    let local = task::LocalSet::new();
    local
        .run_until(async move {
            // `spawn_local` ensures that the future is spawned on the local task set.
            task::spawn_local(MssqlManager::run(recvSQL, sendQueryResults))
                .await
                .unwrap();
        })
        .await;
}
pub struct MssqlManager {}

impl MssqlManager {
    pub async fn run(
        mut recvSQL: Receiver<SQLQueryChannelMsg>,
        mut sendQueryResults: Sender<SQLQueryChannelMsg>,
    ) {
        let conn_string = get_conn_string();

        let env = create_environment_v3().map_err(|e| e.unwrap()).unwrap();
        let conn = env.connect_with_connection_string(&conn_string).unwrap();

        loop {
            // Listening for queries
            let query = recvSQL.recv().await;

            if let Some(SQLQueryChannelMsg::Query(q)) = query {
                info!("Received query: {}", q);

                let stmt = Statement::with_parent(&conn).unwrap();
                match stmt.exec_direct(&q).unwrap() {
                    Data(mut stmt) => {
                        let mut results: Vec<String> = Vec::new();

                        let cols = stmt.num_result_cols().unwrap();
                        while let Some(mut cursor) = stmt.fetch().unwrap() {
                            for i in 1..(cols + 1) {
                                match cursor.get_data::<&str>(i as u16).unwrap() {
                                    Some(val) => {
                                        //print!(" {}", val)
                                        results.push(val.to_owned());
                                    }
                                    None => print!(" NULL"),
                                }
                            }
                        }

                        // Send back some data
                        sendQueryResults
                            .send(SQLQueryChannelMsg::Result(results.clone()))
                            .await
                            .ok()
                            .unwrap();
                    }

                    NoData(_) => println!("Query executed, no data returned"),
                };
            }
        }
    }
}

```

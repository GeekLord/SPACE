use crate::emit::{counter, tag};

pub fn recreate(db_name: &str) {
    counter("db.sqlite.recreate", 1, &[tag("db_name", db_name)]);
}

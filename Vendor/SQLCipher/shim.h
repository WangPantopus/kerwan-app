#ifndef SQLCIPHER_SHIM_H
#define SQLCIPHER_SHIM_H

// SQLCipher provides a drop-in replacement for SQLite with AES-256 encryption.
// When installed via Homebrew (`brew install sqlcipher`), the headers are at:
//   /opt/homebrew/opt/sqlcipher/include/sqlcipher/sqlite3.h (Apple Silicon)
//   /usr/local/opt/sqlcipher/include/sqlcipher/sqlite3.h (Intel)
//
// The pkg-config file (`sqlcipher.pc`) handles include/lib paths automatically.
#include <sqlite3.h>

#endif /* SQLCIPHER_SHIM_H */

# AcmeDB: An Overview

AcmeDB is a lightweight key-value database built around durability and simplicity. Here is a quick look at what it offers, where it falls short, and whether it is right for you.

## Key Features

- **Durable storage:** every write goes through a write-ahead log before it is acknowledged.
- **Simple operations:** there is no consensus layer or sharding scheme to manage.
- **Clear documentation:** the docs answer the questions developers actually ask.

## Limitations

- There is no managed backup solution yet; snapshots are listed as coming soon.
- Deployments are limited to a single region.
- Published performance numbers come from the vendor and have not been independently verified.

## Performance

According to the vendor, AcmeDB delivers p99 read latencies under 2ms. These results were measured on a laptop, so real-world performance may vary depending on your hardware and workload. It is a good idea to run your own benchmarks before relying on these numbers.

## Who Should Use It?

AcmeDB is a good fit for caches, prototypes, and internal services where simplicity matters more than advanced features. Teams that need multi-region availability or strong backup guarantees should probably look elsewhere for now.

## Conclusion

Overall, AcmeDB is a solid, no-frills database that does one thing well. If its limitations are acceptable for your use case, it is worth trying. Just make sure you have a plan for backups until the official solution ships.

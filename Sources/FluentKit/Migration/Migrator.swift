import Foundation

public struct Migrator {
    public let migrations: Migrations
    public let databases: Databases
    public let eventLoop: EventLoop
    
    public init(databases: Databases, migrations: Migrations, on eventLoop: EventLoop) {
        self.databases = databases
        self.migrations = migrations
        self.eventLoop = eventLoop
    }
    
    
    #warning("TODO: handle identical migration added to two dbs")
    
    // MARK: Setup
    
    public func setupIfNeeded() -> EventLoopFuture<Void> {
        return self.databases.default().query(MigrationLog.self).all().map { migrations in
            return ()
        }.flatMapError { error in
            return MigrationLog.autoMigration().prepare(on: self.databases.default())
        }
    }
    
    // MARK: Prepare
    
    public func prepareBatch() -> EventLoopFuture<Void> {
        return self.unpreparedMigrations().flatMap { migrations in
            return .andAllSync(migrations.map { item in
                return { self.prepare(item) }
            }, eventLoop: self.eventLoop)
        }
    }
    
    // MARK: Revert
    
    public func revertLastBatch() -> EventLoopFuture<Void> {
        return self.lastBatchNumber().flatMap { self.revertBatch(number: $0) }
    }
    
    public func revertBatch(number: Int) -> EventLoopFuture<Void> {
        return self.preparedMigrations(batch: number).flatMap { migrations in
            return EventLoopFuture<Void>.andAllSync(migrations.map { item in
                return { self.revert(item) }
            }, eventLoop: self.eventLoop)
        }
    }
    
    public func revertAllBatches() -> EventLoopFuture<Void> {
        return self.preparedMigrations().flatMap { migrations in
            return EventLoopFuture<Void>.andAllSync(migrations.map { item in
                return { self.revert(item) }
            }, eventLoop: self.eventLoop)
        }.flatMap { _ in
            return self.revertMigrationLog()
        }
    }
    
    // MARK: Preview
    
    public func previewPrepareBatch() -> EventLoopFuture<[(Migration, DatabaseID?)]> {
        return self.unpreparedMigrations().map { items -> [(Migration, DatabaseID?)] in
            return items.map { item -> (Migration, DatabaseID?) in
                return (item.migration, item.id)
            }
        }
    }
    
    public func previewRevertLastBatch() -> EventLoopFuture<[(Migration, DatabaseID?)]> {
        return self.lastBatchNumber().flatMap { lastBatch in
            return self.preparedMigrations(batch: lastBatch)
        }.map { items -> [(Migration, DatabaseID?)] in
            return items.map { item -> (Migration, DatabaseID?) in
                return (item.migration, item.id)
            }
        }
    }
    
    public func previewRevertBatch(number: Int) -> EventLoopFuture<[(Migration, DatabaseID?)]> {
        return self.preparedMigrations(batch: number).map { items -> [(Migration, DatabaseID?)] in
            return items.map { item -> (Migration, DatabaseID?) in
                return (item.migration, item.id)
            }
        }
    }
    
    public func previewRevertAllBatches() -> EventLoopFuture<[(Migration, DatabaseID?)]> {
        return self.preparedMigrations().map { items -> [(Migration, DatabaseID?)] in
            return items.map { item -> (Migration, DatabaseID?) in
                return (item.migration, item.id)
            }
        }
    }
    
    // MARK: Private
    
    private func prepare(_ item: Migrations.Item) -> EventLoopFuture<Void> {
        let database: Database
        if let id = item.id {
            #warning("TODO: fix force unwrap")
            database = self.databases.database(id)!
        } else {
            database = self.databases.default()
        }
        return item.migration.prepare(on: database).flatMap {
            return MigrationLog(
                name: item.migration.name,
                batch: 1,
                createdAt: .init(),
                updatedAt: .init()
            ).save(on: self.databases.default())
        }
    }
    
    private func revert(_ item: Migrations.Item) -> EventLoopFuture<Void> {
        let database: Database
        if let id = item.id {
            #warning("TODO: fix force unwrap")
            database = self.databases.database(id)!
        } else {
            database = self.databases.default()
        }
        return item.migration.revert(on: database).flatMap { _ -> EventLoopFuture<Void> in
            return self.databases.default().query(MigrationLog.self)
                .filter(\.name == item.migration.name)
                .delete()
        }
    }
    
    private func revertMigrationLog() -> EventLoopFuture<Void> {
        return MigrationLog.autoMigration().revert(on: self.databases.default())
    }
    
    private func lastBatchNumber() -> EventLoopFuture<Int> {
        #warning("TODO: use db sorting")
        return self.databases.default().query(MigrationLog.self).all().map { logs in
            return logs.sorted(by: { $0.batch.value > $1.batch.value })
                .first?.batch.value ?? 0
        }
    }
    
    private func preparedMigrations() -> EventLoopFuture<[Migrations.Item]> {
        return self.databases.default().query(MigrationLog.self).all().map { logs -> [Migrations.Item] in
            return logs.compactMap { log in
                if let item = self.migrations.storage.filter({ $0.migration.name == log.name.value }).first {
                    return item
                } else {
                    print("No registered migration found for \(log.name.value)")
                    return nil
                }
            }.reversed()
        }
    }
    
    private func preparedMigrations(batch: Int) -> EventLoopFuture<[Migrations.Item]> {
        return self.databases.default().query(MigrationLog.self).filter(\.batch == batch).all().map { logs -> [Migrations.Item] in
            return logs.compactMap { log in
                if let item = self.migrations.storage.filter({ $0.migration.name == log.name.value }).first {
                    return item
                } else {
                    print("No registered migration found for \(log.name.value)")
                    return nil
                }
            }.reversed()
        }
    }
    
    private func unpreparedMigrations() -> EventLoopFuture<[Migrations.Item]> {
        return self.databases.default().query(MigrationLog.self).all().map { logs -> [Migrations.Item] in
            return self.migrations.storage.compactMap { item in
                if logs.filter({ $0.name.value == item.migration.name }).count == 0 {
                    return item
                } else {
                    // log found, this has been prepared
                    return nil
                }
            }
        }
    }
}

private extension EventLoopFuture {
    static func andAllSync(
        _ futures: [() -> EventLoopFuture<Void>],
        eventLoop: EventLoop
    ) -> EventLoopFuture<Void> {
        let promise = eventLoop.makePromise(of: Void.self)
        
        var iterator = futures.makeIterator()
        func handle(_ future: () -> EventLoopFuture<Void>) {
            future().whenComplete { res in
                switch res {
                case .success:
                    if let next = iterator.next() {
                        handle(next)
                    } else {
                        promise.succeed(())
                    }
                case .failure(let error):
                    promise.fail(error)
                }
            }
        }
        
        if let first = iterator.next() {
            handle(first)
        } else {
            promise.succeed(())
        }
        
        return promise.futureResult
    }
}

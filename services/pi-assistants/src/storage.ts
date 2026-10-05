import { openNodeSqliteDatabase } from "@earendil-works/pi-durable/storage/sqlite/node";

export async function openDurableDatabase(path: string) {
  const database = await openNodeSqliteDatabase(path);
  try {
    // Admission is acknowledged to Telegram only after a power-loss durable commit.
    await database.exec("PRAGMA synchronous=FULL");
    return database;
  } catch {
    await database.close();
    throw new Error("Durable storage configuration failed");
  }
}

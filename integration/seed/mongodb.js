// Shared e2e fixture (MongoDB). Applied with `mongosh dbui` INSIDE the
// container (run.sh). Collections mirror the SQL seeds' tables.
db = db.getSiblingDB('dbui');
db.people.drop();
db.people.insertMany([
  { _id: 1, name: 'Ann', note: null, amount: 10.5 },
  { _id: 2, name: "O'Brien", note: 'has, comma', amount: 20.0 },
  { _id: 3, name: 'Zoe', note: 'line one', amount: 3.25 },
  { _id: 4, name: 'Ünïcödé', note: 'tab here & <b>', amount: null },
]);
db.orders.drop();
db.orders.insertMany([
  { _id: 1, person_id: 1, label: 'first' },
  { _id: 2, person_id: 2, label: 'second' },
  { _id: 3, person_id: 2, label: 'third' },
]);
db.numbers.drop();
db.numbers.insertMany(Array.from({ length: 250 }, (_, i) => ({ _id: i + 1, n: i + 1 })));

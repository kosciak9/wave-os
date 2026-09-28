// Fixed labels and seed: never shuffle the calibration/heldout assignment at runtime.
export const SEED = 460942;

const entries = [
  // Calibration: one or two examples of each interaction family.
  ['search', 'Find the Cedar Desk lamp and save it to a shortlist.', 'Cedar Desk lamp', 'Harbor Wall lamp'],
  ['booking', 'Request a table at Fern Kitchen for 3 on 2027-04-12 at 19:00.', 'Fern Kitchen', 'Juniper Kitchen'],
  ['forms', 'Submit a delivery request for Lark Station, express, on 2027-05-06.', 'Lark Station', 'Marsh Station'],
  ['login', 'Sign in to the demo dashboard, open Reports and save the Quarterly filter.', 'Reports', 'Activity'],
  ['cart', 'Add two Moss Notebooks to the cart, then stop before checkout.', 'Moss Notebook', 'Stone Notebook'],
  ['spa', 'In the directory, open the Violet Studio detail and pin it.', 'Violet Studio', 'Amber Studio'],
  ['long', 'Complete the four-stage conference itinerary for North Pier, window seat, and vegetarian meal.', 'North Pier', 'South Pier'],
  ['search', 'Locate the Lantern Lecture event and save it to a shortlist.', 'Lantern Lecture', 'Lantern Workshop'],
  ['booking', 'Request a hotel room at Pine House for 2 on 2027-06-14 at 16:00.', 'Pine House', 'Pine Lodge'],
  ['forms', 'Submit a pickup request for Elm Terminal, standard, on 2027-07-09.', 'Elm Terminal', 'Ash Terminal'],
  // Heldout: different data and targets within the same seven layout families.
  ['search', 'Find the Solar Field guide and save it to a shortlist.', 'Solar Field guide', 'Lunar Field guide'],
  ['search', 'Find the Tidepool Exhibit and save it to a shortlist.', 'Tidepool Exhibit', 'Tidepool Tour'],
  ['search', 'Find the Blueberry Market and save it to a shortlist.', 'Blueberry Market', 'Blueberry Fair'],
  ['booking', 'Request a cinema seat at Orbit Screen for 1 on 2027-08-21 at 20:00.', 'Orbit Screen', 'Orbit Hall'],
  ['booking', 'Request a ferry inquiry at Willow Quay for 2 on 2027-09-13 at 10:00.', 'Willow Quay', 'Willow Dock'],
  ['booking', 'Request a table at Meadow Cafe for 4 on 2027-10-05 at 18:30.', 'Meadow Cafe', 'Meadow Diner'],
  ['forms', 'Submit a delivery request for Birch Depot, express, on 2027-11-17.', 'Birch Depot', 'Cypress Depot'],
  ['forms', 'Submit a pickup request for Iris Hub, standard, on 2027-12-03.', 'Iris Hub', 'Daisy Hub'],
  ['forms', 'Submit a delivery request for Silver Station, standard, on 2028-01-19.', 'Silver Station', 'Gold Station'],
  ['login', 'Sign in to the demo dashboard, open Activity and save the Weekly filter.', 'Activity', 'Reports'],
  ['login', 'Sign in to the demo dashboard, open Reports and save the Monthly filter.', 'Reports', 'Activity'],
  ['login', 'Sign in to the demo dashboard, open Activity and save the Quarterly filter.', 'Activity', 'Reports'],
  ['cart', 'Add three Reed Pencils to the cart, then stop before checkout.', 'Reed Pencil', 'Oak Pencil'],
  ['cart', 'Add one Cloud Mug to the cart, then stop before checkout.', 'Cloud Mug', 'Rain Mug'],
  ['cart', 'Add two Copper Folders to the cart, then stop before checkout.', 'Copper Folder', 'Bronze Folder'],
  ['spa', 'In the directory, open the Saffron Gallery detail and pin it.', 'Saffron Gallery', 'Cobalt Gallery'],
  ['spa', 'In the directory, open the Otter Workshop detail and pin it.', 'Otter Workshop', 'Heron Workshop'],
  ['spa', 'In the directory, open the Coral Library detail and pin it.', 'Coral Library', 'Pearl Library'],
  ['long', 'Complete the four-stage conference itinerary for East Cove, aisle seat, and vegan meal.', 'East Cove', 'West Cove'],
  ['long', 'Complete the four-stage conference itinerary for Maple Point, window seat, and standard meal.', 'Maple Point', 'Birch Point'],
];

function seededOrder(index) {
  // Stable seeded decoy position, avoiding a systematic "first result is correct" shortcut.
  let x = (SEED ^ Math.imul(index + 1, 0x9e3779b1)) >>> 0;
  x ^= x << 13;
  x ^= x >>> 17;
  x ^= x << 5;
  return (x >>> 0) % 2;
}

export const tasks = entries.map(([category, goal, target, decoy], index) => {
  const id = `${category}-${String(index + 1).padStart(2, '0')}`;
  const date = goal.match(/202\d-\d\d-\d\d/)?.[0];
  const time = goal.match(/\b\d\d:\d\d\b/)?.[0];
  const party = Number(goal.match(/\bfor (\d+)\b/)?.[1]);
  const quantity = Number(goal.match(/\b(one|two|three)\b/)?.[1] &&
    { one: 1, two: 2, three: 3 }[goal.match(/\b(one|two|three)\b/)[1]]);
  const filter = goal.match(/\b(Quarterly|Monthly|Weekly)\b/)?.[1];
  const service = goal.match(/\b(express|standard)\b/)?.[1];
  const seat = goal.match(/\b(window|aisle) seat\b/)?.[1];
  const meal = goal.match(/\b(vegetarian|vegan|standard) meal\b/)?.[1];
  const itinerary = category === 'long' ? {
    destination: target, arrival: '2028-04-12', travel: 'Rail', reference: 'Conference',
    attendee: 'Guest Delegate', seat, access: 'None', ticket: 'Standard',
    meal, session: 'Strategy', venue: 'North', reminder: 'Email',
    summary: 'Conference visit', timezone: 'UTC', contact: 'Office Desk', confirm: 'Reviewed',
  } : null;
  const fullGoal = itinerary ? `${goal} Enter these values across the four stages: destination ${target}; arrival date ${itinerary.arrival}; travel mode ${itinerary.travel}; reference label ${itinerary.reference}; attendee alias ${itinerary.attendee}; seat preference ${seat}; accessibility note ${itinerary.access}; ticket tier ${itinerary.ticket}; meal preference ${meal}; session track ${itinerary.session}; venue wing ${itinerary.venue}; reminder ${itinerary.reminder}; summary title ${itinerary.summary}; time zone ${itinerary.timezone}; contact alias ${itinerary.contact}; review status ${itinerary.confirm}.` : goal;
  return Object.freeze({
    id, category, goal: fullGoal, split: index < 10 ? 'calibration' : 'heldout',
    variables: Object.freeze({ target, ...(date && { date }), ...(time && { time }),
      ...(party && { party }), ...(quantity && { quantity }), ...(filter && { filter }),
      ...(service && { service }), ...(seat && { seat }), ...(meal && { meal }),
      ...itinerary }),
    target, decoy, options: seededOrder(index) ? [decoy, target] : [target, decoy],
  });
});

export const taskById = new Map(tasks.map(task => [task.id, task]));

// No internal target/decoy identifiers or expected action sequence in the public manifest.
export function manifest() {
  return tasks.map(({ id, category, goal, split, variables }) => ({
    id, category, goal, split, variables,
    start_path: `/run/{runId}/${id}/start`,
    max_steps: category === 'long' ? 75 : 35,
  }));
}

"""Themed content packs: rooms with furniture palettes, names and case titles.
All names and titles here are our own."""

# Canonical object id for each object word we use (ids from murdoku_objects.lua).
OBJ_ID = {
    'plant': 1, 'chair': 2, 'tv': 3, 'table': 4, 'bed': 6, 'bed-v': 7, 'crate': 9, 'tree': 10, 'fire': 12,
    'shelf': 13, 'trashcan': 14, 'horse': 15, 'cactus': 16, 'cow': 17, 'statue': 20, 'car': 21,
    'rowboat': 25, 'register': 28, 'barrel': 32, 'puddle': 34, 'shrub': 37, 'box': 42, 'boulder': 43,
    'bonsai': 44, 'locker': 45, 'punching bag': 46, 'pig': 48, 'gas pump': 49, 'cone': 57, 'basket': 60,
    'stump': 66, 'golf cart': 71, 'water': 72, 'flowers': 80, 'easel': 81, 'camera': 82, 'safe': 83,
    'tombstone': 85, 'piano': 86, 'hay': 87, 'sack': 89, 'column': 102, 'chest': 117, 'raft': 124,
    'hammock': 129, 'drum set': 145, 'speaker': 148, 'sign': 149, 'lamppost': 150, 'pumpkin': 41,
}
TWO_WIDE = {'bed', 'car'}      # stored at the left cell, covers the cell to the right
TWO_TALL = {'bed-v'}           # covers the cell below

# How a person is "on" a standable object, used in clue text: (phrase before noun)
ON_VERB = {
    'chair': 'sitting in', 'bed': 'on', 'car': 'in', 'rowboat': 'in', 'puddle': 'standing in',
    'horse': 'on', 'hammock': 'in', 'carpet': 'on', 'raft': 'on', 'golf cart': 'in',
}
# Nouns that take "some" instead of "a" (and never "the").
MASS = {'flowers', 'hay'}
# Display noun for clue text where it differs from the object word.
NOUN = {'tv': 'TV', 'bed-v': 'bed'}

C = 'carpet'
THEMES = {
    'lighthouse': dict(
        titles=['The Haunted Lighthouse', 'Storm at the Lighthouse', 'The Keeper\'s Last Watch', 'Fog on the Rocks'],
        rooms=[
            ('Lamp Room', [('chair', 2), ('box', 1), ('barrel', 1)]),
            ('Keeper\'s Cottage', [('bed', 2), ('chair', 2), ('table', 2), ('shelf', 1), (C, 1)]),
            ('Boathouse', [('rowboat', 3), ('crate', 2), ('barrel', 2)]),
            ('Cliff Path', [('boulder', 3), ('shrub', 2), ('flowers', 1)]),
            ('Store Room', [('crate', 2), ('barrel', 2), ('sack', 2), ('box', 1)]),
            ('Jetty', [('rowboat', 2), ('barrel', 1), ('water', 2)]),
            ('Signal Hut', [('table', 1), ('chair', 2), ('shelf', 1)]),
            ('Garden', [('flowers', 2), ('shrub', 2), ('tree', 1), ('chair', 1)]),
            ('Beach', [('boulder', 2), ('puddle', 2), ('raft', 1)]),
        ]),
    'manor': dict(
        titles=['Midnight at the Manor', 'The Ballroom Affair', 'A Will and a Way', 'The Last Dinner Party'],
        rooms=[
            ('Library', [('shelf', 4), ('chair', 2), ('table', 1), (C, 2)]),
            ('Ballroom', [('piano', 1), ('statue', 1), (C, 3), ('chair', 2)]),
            ('Conservatory', [('plant', 3), ('flowers', 2), ('bonsai', 1), ('chair', 1)]),
            ('Kitchen', [('table', 2), ('chair', 2), ('shelf', 1), ('barrel', 1)]),
            ('Study', [('shelf', 2), ('table', 1), ('chair', 2), ('safe', 1), (C, 1)]),
            ('Dining Room', [('table', 3), ('chair', 4), ('plant', 1)]),
            ('Master Bedroom', [('bed', 2), (C, 2), ('shelf', 1), ('plant', 1)]),
            ('Hall', [('statue', 1), (C, 2), ('plant', 2)]),
            ('Billiard Room', [('table', 2), ('chair', 2), ('shelf', 1)]),
        ]),
    'museum': dict(
        titles=['The Midnight Museum', 'A Missing Masterpiece', 'Night of the Mummy', 'The Curator\'s Secret'],
        rooms=[
            ('Sculpture Hall', [('statue', 3), ('column', 2), (C, 1)]),
            ('Painting Gallery', [('easel', 2), ('chair', 2), (C, 2)]),
            ('Gift Shop', [('register', 1), ('shelf', 2), ('box', 1)]),
            ('Vault', [('safe', 2), ('chest', 1), ('crate', 1)]),
            ('Cafe', [('table', 2), ('chair', 3), ('plant', 1)]),
            ('Lobby', [('plant', 2), (C, 2), ('sign', 1)]),
            ('Workshop', [('table', 1), ('crate', 2), ('box', 1), ('chair', 1)]),
            ('Egyptian Room', [('column', 2), ('chest', 1), ('statue', 1)]),
            ('Security Office', [('camera', 1), ('chair', 2), ('table', 1), ('locker', 1)]),
        ]),
    'campsite': dict(
        titles=['The Last Campfire', 'Lost in the Pines', 'Ghost Stories', 'Mosquito Season'],
        rooms=[
            ('Campfire', [('fire', 1), ('stump', 2), ('chair', 2)]),
            ('Lake', [('water', 3), ('rowboat', 2), ('raft', 1)]),
            ('Woods', [('tree', 4), ('boulder', 1), ('shrub', 2)]),
            ('Hammock Grove', [('hammock', 3), ('tree', 2)]),
            ('Parking Area', [('car', 3), ('sign', 1), ('puddle', 1)]),
            ('Log Cabin', [('bed', 2), ('table', 1), ('chair', 2)]),
            ('Ranger Station', [('table', 1), ('chair', 1), ('shelf', 1), ('sign', 1)]),
            ('Meadow', [('flowers', 3), ('shrub', 1), ('boulder', 1)]),
            ('Trail', [('tree', 2), ('stump', 1), ('puddle', 2)]),
        ]),
    'theatre': dict(
        titles=['Curtain Call', 'Death of a Diva', 'The Final Act', 'Opening Night'],
        rooms=[
            ('Stage', [('speaker', 2), ('drum set', 1), ('piano', 1), ('chair', 2)]),
            ('Dressing Room', [('chair', 3), ('shelf', 1), ('plant', 1), ('locker', 1)]),
            ('Box Office', [('register', 1), ('chair', 1), ('sign', 1)]),
            ('Foyer', [(C, 3), ('plant', 2), ('statue', 1)]),
            ('Orchestra Pit', [('piano', 1), ('chair', 3), ('speaker', 1)]),
            ('Prop Room', [('box', 2), ('crate', 1), ('chest', 2)]),
            ('Balcony', [('chair', 4), (C, 1)]),
            ('Bar', [('table', 2), ('chair', 2), ('barrel', 1)]),
            ('Green Room', [('chair', 2), ('table', 1), ('tv', 1), (C, 1)]),
        ]),
    'farm': dict(
        titles=['Trouble on the Farm', 'Harvest Moon', 'The Scarecrow Knows', 'Muddy Boots'],
        rooms=[
            ('Barn', [('hay', 3), ('horse', 2), ('cow', 1)]),
            ('Pigsty', [('pig', 2), ('puddle', 3)]),
            ('Farmhouse Kitchen', [('table', 2), ('chair', 3), ('barrel', 1)]),
            ('Orchard', [('tree', 4), ('basket', 1)]),
            ('Pumpkin Patch', [('pumpkin', 3), ('shrub', 1)]),
            ('Yard', [('car', 2), ('puddle', 1), ('crate', 1)]),
            ('Stable', [('horse', 3), ('hay', 2)]),
            ('Tool Shed', [('box', 2), ('shelf', 1), ('sack', 2)]),
            ('Duck Pond', [('water', 3), ('rowboat', 1)]),
        ]),
    'hotel': dict(
        titles=['Checkout Time', 'Do Not Disturb', 'Room Service', 'The Penthouse Suite'],
        rooms=[
            ('Lobby', [(C, 3), ('plant', 2), ('chair', 2)]),
            ('Reception', [('register', 1), ('chair', 1), ('plant', 1)]),
            ('Suite', [('bed', 2), ('tv', 1), (C, 2), ('chair', 1)]),
            ('Pool', [('water', 3), ('chair', 3)]),
            ('Restaurant', [('table', 3), ('chair', 4)]),
            ('Bar', [('barrel', 1), ('chair', 3), ('register', 1)]),
            ('Car Park', [('car', 3), ('cone', 1), ('lamppost', 1)]),
            ('Gym', [('punching bag', 2), ('locker', 2)]),
            ('Laundry', [('box', 2), ('shelf', 2), ('puddle', 1)]),
        ]),
    'station': dict(
        titles=['The Last Train', 'Platform Nine', 'Delayed Departure', 'The Night Express'],
        rooms=[
            ('Platform', [('lamppost', 2), ('sign', 1), ('chair', 3)]),
            ('Ticket Office', [('register', 1), ('chair', 2), ('shelf', 1)]),
            ('Waiting Room', [('chair', 4), ('plant', 1), ('trashcan', 1)]),
            ('Station Cafe', [('table', 2), ('chair', 3)]),
            ('Luggage Room', [('box', 2), ('crate', 2), ('chest', 1)]),
            ('Taxi Rank', [('car', 3), ('sign', 1), ('puddle', 1)]),
            ('Signal Box', [('table', 1), ('chair', 1), ('shelf', 1)]),
            ('Newsstand', [('shelf', 2), ('register', 1)]),
            ('Footbridge', [('lamppost', 1), ('puddle', 2)]),
        ]),
    'school': dict(
        titles=['Detention', 'The Science Fair', 'Exam Day', 'Reunion Night'],
        rooms=[
            ('Classroom', [('table', 3), ('chair', 4), ('shelf', 1)]),
            ('Gym', [('punching bag', 2), ('locker', 2), ('cone', 2)]),
            ('Library', [('shelf', 4), ('chair', 2), ('table', 1)]),
            ('Art Room', [('easel', 3), ('table', 1), ('chair', 2)]),
            ('Music Room', [('piano', 1), ('drum set', 1), ('speaker', 1), ('chair', 2)]),
            ('Playground', [('tree', 2), ('puddle', 2), ('shrub', 1)]),
            ('Cafeteria', [('table', 3), ('chair', 4), ('trashcan', 1)]),
            ('Principal\'s Office', [('table', 1), ('chair', 2), ('safe', 1), ('plant', 1)]),
            ('Locker Hall', [('locker', 4), ('trashcan', 1)]),
        ]),
    'ski lodge': dict(
        titles=['Snowed In', 'Avalanche Warning', 'The Frozen Lake', 'Black Run'],
        rooms=[
            ('Fireside Lounge', [('fire', 1), ('chair', 3), (C, 2)]),
            ('Ski Room', [('locker', 3), ('box', 1)]),
            ('Dining Hall', [('table', 3), ('chair', 4)]),
            ('Bunk Room', [('bed', 3), ('locker', 1)]),
            ('Slope', [('tree', 3), ('boulder', 1), ('sign', 1)]),
            ('Hot Tub', [('water', 2), ('chair', 2)]),
            ('Frozen Lake', [('water', 2), ('boulder', 1), ('raft', 1)]),
            ('Equipment Shop', [('register', 1), ('shelf', 2), ('box', 1)]),
            ('Car Park', [('car', 3), ('lamppost', 1)]),
        ]),
    'harbour': dict(
        titles=['The Smugglers\' Cove', 'Low Tide', 'The Captain\'s Chest', 'Rum and Rope'],
        rooms=[
            ('Dock', [('rowboat', 3), ('barrel', 2)]),
            ('Tavern', [('table', 2), ('chair', 3), ('barrel', 1)]),
            ('Beach', [('boulder', 2), ('raft', 1), ('puddle', 2)]),
            ('Cave', [('chest', 2), ('boulder', 2)]),
            ('Warehouse', [('crate', 3), ('sack', 2), ('barrel', 1)]),
            ('Fish Market', [('table', 2), ('register', 1), ('basket', 2)]),
            ('Harbour Office', [('table', 1), ('chair', 2), ('safe', 1)]),
            ('Shipyard', [('crate', 1), ('rowboat', 2), ('box', 1)]),
            ('Lookout', [('chair', 1), ('barrel', 1), ('boulder', 1)]),
        ]),
    'garden party': dict(
        titles=['The Garden Party', 'Poison in the Punch', 'A Thorny Problem', 'Tea for Two'],
        rooms=[
            ('Rose Garden', [('flowers', 4), ('shrub', 2), ('chair', 1)]),
            ('Lawn', [('chair', 3), ('table', 2), (C, 2)]),
            ('Greenhouse', [('plant', 3), ('bonsai', 2), ('flowers', 1)]),
            ('Pond', [('water', 3), ('rowboat', 1)]),
            ('Gazebo', [('chair', 3), ('table', 1)]),
            ('Hedge Maze', [('shrub', 4), ('statue', 1)]),
            ('Orchard', [('tree', 3), ('basket', 1), ('hammock', 1)]),
            ('Potting Shed', [('box', 2), ('shelf', 1), ('sack', 1)]),
            ('Driveway', [('car', 2), ('puddle', 1)]),
        ]),
    'diner': dict(
        titles=['Late Shift at the Diner', 'Cold Coffee', 'Last Orders', 'The Midnight Special'],
        rooms=[
            ('Counter', [('register', 1), ('chair', 3)]),
            ('Booths', [('table', 3), ('chair', 4)]),
            ('Kitchen', [('fire', 1), ('shelf', 2), ('table', 1)]),
            ('Parking Lot', [('car', 3), ('lamppost', 1), ('puddle', 1)]),
            ('Restroom', [('puddle', 2), ('trashcan', 1)]),
            ('Jukebox Corner', [('speaker', 2), ('chair', 2), (C, 1)]),
            ('Store Room', [('box', 2), ('sack', 2), ('barrel', 1)]),
            ('Gas Station', [('gas pump', 2), ('car', 1), ('sign', 1)]),
            ('Back Alley', [('trashcan', 2), ('crate', 1), ('puddle', 1)]),
        ]),
    'churchyard': dict(
        titles=['The Haunted Churchyard', 'Midnight Mass', 'Grave Matters', 'The Bell Tolls'],
        rooms=[
            ('Graveyard', [('tombstone', 4), ('tree', 1)]),
            ('Chapel', [('chair', 4), ('statue', 1), (C, 2)]),
            ('Crypt', [('column', 2), ('chest', 1)]),
            ('Bell Tower', [('box', 1), ('chair', 1)]),
            ('Vicarage', [('bed', 2), ('table', 1), ('chair', 2), ('shelf', 1)]),
            ('Cloister Garden', [('flowers', 2), ('shrub', 2), ('statue', 1)]),
            ('Vestry', [('shelf', 2), ('chest', 1), ('chair', 1)]),
            ('Lych Gate', [('lamppost', 1), ('puddle', 2)]),
            ('Old Yew Grove', [('tree', 3), ('stump', 1)]),
        ]),
}

# Names per letter: the suspect with letter A has an A name, and so on. Our own lists.
FEMALE = {
    'A': ['Ada', 'Agnes', 'Alma', 'Amber', 'Aurora'], 'B': ['Bella', 'Bianca', 'Brenda', 'Beatrix', 'Bonnie'],
    'C': ['Clara', 'Cora', 'Cecily', 'Carmen', 'Celeste'], 'D': ['Daisy', 'Delia', 'Dora', 'Dahlia', 'Dinah'],
    'E': ['Edith', 'Elsa', 'Esme', 'Eleanor', 'Erin'], 'F': ['Fiona', 'Flora', 'Freya', 'Faye', 'Florence'],
    'G': ['Greta', 'Gwen', 'Grace', 'Gloria', 'Gemma'], 'H': ['Hazel', 'Hilda', 'Harriet', 'Helena', 'Holly'],
}
MALE = {
    'A': ['Arlo', 'Albert', 'Amos', 'Angus', 'Archie'], 'B': ['Boris', 'Basil', 'Bruno', 'Barnaby', 'Bert'],
    'C': ['Cyril', 'Clement', 'Conrad', 'Cedric', 'Colin'], 'D': ['Dante', 'Dexter', 'Duncan', 'Desmond', 'Douglas'],
    'E': ['Elliot', 'Edgar', 'Ernest', 'Emil', 'Ezra'], 'F': ['Felix', 'Fergus', 'Frank', 'Floyd', 'Frederick'],
    'G': ['Gus', 'Gideon', 'Gilbert', 'Gordon', 'Grant'], 'H': ['Hugo', 'Horace', 'Harvey', 'Henry', 'Howard'],
}
VICTIM_F = ['Vera', 'Violet', 'Vivian', 'Valerie', 'Velma', 'Vanessa']
VICTIM_M = ['Victor', 'Vince', 'Vaughn', 'Vernon', 'Virgil', 'Valentine']


def obj_word(o):
    """Object word (key of OBJ_ID) for an id, or None."""
    for w, i in OBJ_ID.items():
        if i == o:
            return 'bed' if w == 'bed-v' else w
    return None

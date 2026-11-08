# Murdoku for KOReader: third-party art attribution

Per-icon detail (set, author, licence, source name) is in `mapping.json`. This file lists the
obligations and the exact credit text to ship in the plugin's About screen and in its README.

## Short credit text (About screen)

> Object icons by Delapouite, Lorc, Skoll, Caro Asercion, John Redman, Pierre Leducq, Faithtoken and HeavenlyDog
> from game-icons.net (CC BY 3.0); Fluent Emoji High Contrast © Microsoft (MIT);
> Material Design Icons © Pictogrammers (Apache 2.0); Temaki by Bryan Housel (CC0); Lucide icons (ISC).
> Suspect portraits are built from Open Peeps by Pablo Stanley (CC0), via DiceBear (MIT).

## Obligations by source

| Source | Used for | Licence | What we must do |
|---|---|---|---|
| **game-icons.net** (https://game-icons.net, https://github.com/game-icons/icons) | 118 object icons | **CC BY 3.0** (https://creativecommons.org/licenses/by/3.0/) | Credit **each author**. Their licence.txt asks for: "Icons made by {author}". Link the licence and say we changed the icons (we recoloured `currentColor` to `#000` and stripped the background square through Iconify). |
| **Fluent Emoji High Contrast**, Microsoft (https://github.com/microsoft/fluentui-emoji) | 14 object icons | **MIT** | Ship the MIT copyright notice: "Copyright (c) Microsoft Corporation." plus the MIT permission text. |
| **Material Design Icons**, Pictogrammers (https://github.com/Templarian/MaterialDesign) | 12 object icons, plus the optional MDI toolbar set | **Apache-2.0** | Include the Apache-2.0 licence text or a link to it. No NOTICE file is needed. |
| **Temaki**, Bryan Housel (https://github.com/rapideditor/temaki) | shrub (37), tree stump (66) | **CC0-1.0** | Nothing required. Credit is courteous. |
| **Hammock** (129, 130) | drawn for this project | CC0-1.0 | None. |
| **Lucide** (https://lucide.dev) | toolbar: x, eraser, undo-2, redo-2, lightbulb, check, menu | **ISC** | Keep the ISC notice: "Copyright (c) for portions of Lucide are held by Cole Bemis 2013-2022 as part of Feather (MIT). All other copyright (c) for Lucide are held by Lucide Contributors 2022." |
| **Open Peeps**, Pablo Stanley (https://www.openpeeps.com/), parts exported by **DiceBear** `@dicebear/open-peeps` 9.4.2 | faces: `faces/parts/**` (103 part files) and `faces/openpeeps_*.svg` | Art **CC0-1.0**. DiceBear code is **MIT** © Florian Körner. | No obligation for the art. If we ship our own port of the composition logic, the MIT notice for DiceBear is courteous; it is required only if we copy their code. |

## game-icons.net authors per icon (CC BY 3.0)

* **Delapouite** (http://delapouite.com): window, wooden-chair, tv, table, bed, wooden-crate, palm-tree, bookshelf, trash-can, cactus, cow, door, stone-bust, stone-pile, sand-castle, shark-fin, house, present, barrel, covered-jar, camel, pumpkin, cardboard-box-closed, bonsai-tree, lockers, punching-bag, gas-pump, bear-head, elephant, penguin, bus, traffic-cone, golf-flag, mammoth, basket, raspberry, saber-toothed-cat-head, tree-door, sailboat, golf-tee, lily-pads, photo-camera, bison, round-straw-bale, coal-pile, old-wagon, dynamite, gold-nuggets, mine-wagon, obelisk, ionic-column, sarcophagus, anubis, eye-of-horus, caravel, egyptian-sphinx, chest, papyrus, rope-coil, raft, paint-bucket, speaker, street-light
* **Lorc** (http://lorcblog.blogspot.com): campfire, spill, crossed-swords, lion, cat, wheat, pocket-bow, wolf-head, stone-axe, crossed-bones, waves, tombstone, swap-bag, monkey, stone-block, galleon, spears, locked-chest, cannon, hourglass, firework-rocket, wooden-sign
* **Skoll**: pig, open-treasure-chest, footsteps
* **Caro Asercion**: boar, easel, grand-piano, drum-kit
* **John Redman** (http://www.uniquedicetowers.com): rock
* **Pierre Leducq**: shooner-sailboat
* **Faithtoken** (http://fungustoken.deviantart.com): nautilus-shell
* **HeavenlyDog** (http://www.gnomosygoblins.blogspot.com): catapult

README wording (CC BY 3.0 compliant):

> Icons made by Delapouite, Lorc, Skoll, Caro Asercion, John Redman, Pierre Leducq, Faithtoken and HeavenlyDog,
> from https://game-icons.net, licensed under CC BY 3.0 (https://creativecommons.org/licenses/by/3.0/).
> Changes: recoloured to black and converted to standalone SVG.

## Licence texts

**MIT** (Fluent Emoji High Contrast, Copyright (c) Microsoft Corporation; DiceBear, Copyright (c) Florian Körner):
Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions: The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED.

**ISC** (Lucide): Copyright (c) for portions of Lucide are held by Cole Bemis 2013-2022 as part of Feather (MIT). All other copyright (c) for Lucide are held by Lucide Contributors 2022. Permission to use, copy, modify, and/or distribute this software for any purpose with or without fee is hereby granted, provided that the above copyright notice and this permission notice appear in all copies. THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES.

**Apache-2.0** (Material Design Icons): https://www.apache.org/licenses/LICENSE-2.0

**CC BY 3.0** (game-icons.net): https://creativecommons.org/licenses/by/3.0/

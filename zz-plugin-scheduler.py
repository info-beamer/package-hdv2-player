import random, time
from itertools import count
from collections import namedtuple, defaultdict

from player_plugin import (
    log, sleep_until, start_worker,
    local_time, tv_power,
    synced_lua_call,
    common_config, local_config,
)

PRELOAD = 4
MAX_SUSPEND_DEPTH = 4

Item = namedtuple(
    "Item",
    "config_hash item_idx duration cnt rnd ovr"
)

FALLBACK_ITEM = Item( # will trigger fallback on lua display
    config_hash = '',
    item_idx = -1,
    duration = 5,
    cnt = 0,
    rnd = 0,
    ovr = [],
)

class AlternativeLooper(object):
    def __init__(self):
        self._count = count(0).next
    def next(self):
        return self._count() % (1*2*3*4*5*6*7*8*9*10)

class ItemGenerator(object):
    def __init__(self):
        # zero-indexed offset into the playlist. Start
        # with -1 so the initial item after incrementing
        # is item 0.
        self._item_idx = -1
        self._item_idx_count = defaultdict(AlternativeLooper)

    def get_next(self):
        config = common_config()
        if config is None:
            log("no common config")
            return None

        now = time.time()

        # find next playable item within the common playlist
        playlist = config.playlist
        overlay_groups = config.overlay_groups
        for probe in xrange(len(playlist)):
            self._item_idx = (self._item_idx + 1) % len(playlist)
            item = playlist[self._item_idx]
            if not item['schedule'].is_active_at(now):
                continue

            duration = item['duration']
            if duration == 0: # auto duration?
                duration = 10
                metadata = item['asset']['metadata']
                if 'duration' in metadata:
                    duration = metadata['duration']

            # Ensure there's at least a small gap between
            # the end of playback of the previous item and
            # the preloading of the next one.
            duration = max(PRELOAD + 1, duration)

            potential_overlay_groups = []
            for overlay_group in overlay_groups:
                # Try to filter out overlay groups that cannot
                # possibly match. Those conditions not handled
                # here are decided within the Lua code on each
                # individual display as they depend on the base
                # asset playing. As that depends on the device,
                # it cannot be decided here.
                active = True
                for condition in overlay_group.get('conditions', ()):
                    condition_type = condition['condition_type']
                    if condition_type == 'schedule':
                        active = active and condition['schedule'].is_active_at(now)
                    elif condition_type == 'slot_type':
                        active = active and (
                            condition['slot_type'] == item['slot_type']
                        )
                    elif condition_type == 'not_slot_type':
                        active = active and (
                            condition['slot_type'] != item['slot_type']
                        )
                if active:
                    potential_overlay_groups.append(overlay_group['_id'])

            return Item(
                config_hash = config.config_hash,
                item_idx = self._item_idx+1,
                duration = duration,
                cnt = self._item_idx_count[self._item_idx].next(),
                rnd = random.randint(0, 2**20),
                ovr = potential_overlay_groups,
            )

        # No playable item found?
        return None


class Plugin(object):
    def __init__(self):
        self._item_generator = ItemGenerator()
        start_worker(self.scheduler)

    def scheduler(self, should_stop):
        next_switch = local_time() + 0.1 + PRELOAD
        suspend_depth = 0

        while not should_stop():
            # Wake up PRELOAD seconds before the next switch
            sleep_until(next_switch - PRELOAD)

            # Decide on next item
            should_blank = local_config().blank
            item = self._item_generator.get_next()
            if item is None:
                log("nothing scheduled. using fallback")
                item = FALLBACK_ITEM
                if should_blank:
                    # Every time no item is scheduled, suspend_depth
                    # gets increased if setup is configured to suspend
                    # displays. Once MAX_SUSPEND_DEPTH is reached, the
                    # screen is turned off.
                    suspend_depth = min(MAX_SUSPEND_DEPTH, suspend_depth+1)
            elif suspend_depth > 0:
                log("items returning. exiting fallback soon")
                # If an item could be scheduled, but suspend_depth
                # hasn't returned to zero yet, play fallback item as
                # a placeholder while the display is slowly turning
                # back on.
                item = FALLBACK_ITEM
                suspend_depth -= 1

            log("next up: %r" % (item,))

            # Set display power status
            tv_power(on = suspend_depth < MAX_SUSPEND_DEPTH or not should_blank)

            # Send preloading instruction to peers. Note that
            # this eats into the preload time as it's scheduled
            # slightly into the future.
            synced_lua_call(0.25, 'preload', item._asdict())

            # Now figure out how much time we have left until
            # the switch. Schedule switching accordingly.
            switch_time = next_switch - local_time()
            synced_lua_call(switch_time, 'switch')

            # Sleep until all screens have switched
            sleep_until(next_switch)

            # Content has switched now. Decide when to switch next.
            next_switch = next_switch + item.duration

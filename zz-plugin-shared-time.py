import time
from datetime import datetime

from hosted.scheduler import utc_to_local

from player_plugin import (
    repeated_call, wall_time, synced_lua_call,
    common_config, send_local_node_data, Plugin,
)

class SharedTime(Plugin):
    def __init__(self):
        repeated_call(2, self.send_time)
        repeated_call(1, self.send_debug_time)

    def send_time(self):
        synced_lua_call(0.5, 'update_time', wall_time()+0.5, time.time()+0.5)

    def send_debug_time(self):
        config = common_config()
        if config is None:
            return

        tz = config.metadata_timezone
        now = utc_to_local(datetime.utcnow(), tz).replace(microsecond = 0)

        send_local_node_data('debug/update',
            local_time = dict(
                local = str(now),
                tz = tz.zone,
            )
        )

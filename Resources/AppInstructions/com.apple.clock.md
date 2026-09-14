## Clock

Supported tasks: add or remove World Clock cities; start, pause, resume and cancel a timer; start, stop, lap and reset the stopwatch; add, edit, remove, enable and disable alarms. Each area is a toolbar tab: click it first unless it is already selected.

### World Clock
1. Click the 'World Clock' tab.
2. Read the existing clocks from the container elements that have exactly one text child. Ignore everything under the 'world map' heading; it is not updated when clocks are removed.
3. If the city is missing, click the toolbar menu button described as 'Add a clock'.
4. In the sheet, `wisp set --app Clock --el <search field> 'City'`, then click the city's text; the city is added and the sheet closes.

### Timer
1. Click the 'Timer' tab and read the current state from the visible buttons.
2. If a timer is running or paused, tell the user and offer to cancel it before starting a new one.
3. Split the requested duration into hours (0-23), minutes (0-59) and seconds (0-59). Refuse anything longer than 23:59:59; the app cannot represent it.
4. Find the container identified as 'TimePicker'; its three sliders are hours, minutes and seconds, in that order.
5. For each slider: `wisp click --app Clock --el N` to focus it, then `wisp type --app Clock '30'` with at most two digits. Do not use `wisp set` on these sliders.
6. Click the button described as 'Start'.

### Stopwatch
Click the 'Stopwatch' tab. If the start/stop button reads 'Stop', the stopwatch is running: offer to stop or restart it. If it reads 'Start', click it.

### Alarm
1. Click the 'Alarm' tab, then the toolbar menu button described as 'Add an alarm'.
2. Set the time with `wisp set` on the date/time area, using the same format as its current value. Ignore the AM/PM radio buttons; they follow the value.
3. Repeat days are seven toggles labelled S M T W T F S; switch on the ones you need.
4. Label, sound and snooze have their own controls. Click 'Save'.

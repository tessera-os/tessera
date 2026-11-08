# 11 — Adaptive Desktop

What a person actually sees and touches. Everything before this is machinery; this
is the machine having a face.

## What it is

A privileged client of the display server ([08](08-display-server.md)). It draws
whatever is not an application — the background, the switcher, the status area —
and it tells the server what to show and who has focus.

It is a client and not part of the server on purpose: policy changes often and a
compositor should not be restarted to change what a launcher looks like. The
privileges it needs are granted by the protocol explicitly, not by being the same
process.

## The window model

Adaptive Desktop is a Dynamic Platform of its own ([15](15-form-factors.md)),
and `adaptive-desktop` is its program. It shares application, surface, focus,
launcher, switcher, and lifecycle state with the other platforms through
PlatformKit (`platform-kit`), a library, and draws with the components of
PlatformUI (`platform-ui`), a private framework. Presentation policy, what is
shown where and when, is each platform's own; how a component looks for a
window model, a navigation model and a viewing distance is PlatformUI's.

Adaptive Desktop uses freeform windows. The compositor owns geometry, stacking,
composition, and input enforcement; the platform owns the policy that moves,
resizes, raises, activates, decorates, and presents those windows. A
fullscreen surface can still use direct scanout when nothing needs composition.

Adaptive Mobile is a separate Dynamic Platform with its own program,
`adaptive-mobile`, using the same application and surface model and the same
PlatformUI components with touch-oriented presentation. Console
and Media use fullscreen presentation and directional navigation rather than
pretending a pointer desktop can simply be scaled up.

The display protocol therefore keeps size, position, stacking, focus, and
presentation mode explicit. Each platform sets its own policy without forking
the compositor, PlatformKit or PlatformUI.

## What the platform owns

### The system bar

A bar along the top edge of the output, above every application, as a Mac's
menu bar is. Applications do not carry one: KiraUI's in-window menu bar is
hidden on Tessera, and nothing an application draws reaches the top band.

Each Dynamic Platform draws its own bar, because what belongs in it
differs by platform ([15](15-form-factors.md)). The bar's building blocks are
KiraUI's system bar APIs, and the items that go in it are PlatformUI's: a
platform composes its bar from them as it composes any other KiraUI interface,
and no platform carries a bar implementation of its own. The bar is a surface
of the platform's, like the background; the display
server composites it over the application in front and knows nothing else
about it ([08](08-display-server.md)).

What the Adaptive Desktop bar holds, from leading to trailing:

- the name of the application in front, then that application's menus;
- the status area (below), at the trailing end.

In `Freeform` the band is kept clear: every application surface is placed
below it, given the output's size less the bar's height, and lays out at that
size. In `Stack` and `Exclusive` an application fills the screen to its top, as
on an iPad, and is told the bar's band as its top inset
([08](08-display-server.md), `insets`), with the band the Dock or the home
indicator takes as its bottom one. A platform that draws no bar configures
applications at the full output with no top inset.

Adaptive Mobile's bar is an iPad's status bar: the time and the date at the
leading end and the status area at the trailing end, in white, with no menus,
over the home screen and over the application in front.

#### Menus come from the application in front

An application declares its menus with KiraUI's `.commands {}`, as on a Mac.
They reach the bar through AppKit, which is the bridge between an application
and whichever platform is running: there are four, and an application does
not know which one it is talking to, so it never talks to one directly.

When PID 1 links an application to the display server, it also mints a platform
link: a channel between the application's AppKit and the running platform, handed
to each end the way display links are ([03](03-processes.md)). On it:

- the application sends its menus when its surface gains focus, and again when
  they change: each menu's title, and each item's title, keyboard shortcut and
  whether it is enabled, all addressed by numbers the application chose;
- the platform sends back the number of the item a person chose, and AppKit runs
  that command in the application as if its own menu had been used.

The platform shows the menus of the surface that has focus and no other. An
application that loses focus stops being shown in the bar; the menus it sent
are kept and shown again when it is in front again. The display server carries
none of this.

While a menu is out, put out by the pointer or by F2, the platform holds the
keyboard, as a Mac's menu bar does: the arrows move through the menus and their
rows, Return chooses, Escape puts the menu away, and the pointer reaches the
menu where it hangs below the bar. When the menu goes the application in front
has the keyboard again.

Keyboard shortcuts do not depend on the bar: a key reaches the focused
application and KiraUI runs the command it is bound to there. The command key
is the keyboard's GUI key, written ⌘, as on a Mac, and menus show shortcuts in
a Mac's glyphs.

### The background

The first thing on screen after the splash, and the thing that says the machine
is alive and idle. A surface the size of the output, behind everything.

The splash ([03](03-processes.md)) is drawn by a different program in the
initramfs; the handover between them should not flash. That means the platform's
first frame is ready *before* the splash stops, which is a real ordering problem
and the reason the display server should not clear to black between the two.

### The switcher

How a person changes which application is in front. Invoked by a key, showing
what is running, and — for a system with no windows — this is the *only* way to
move between applications, so it is not a secondary feature.

The minimum: a key opens it, arrows or number keys choose, release commits. A
list of names is enough; live thumbnails are nicer and need the server to hand
the platform each client's last buffer, which the protocol can do and should not do
until it is wanted.

On Adaptive Desktop the key is F3 and it is a Mac's Command-Tab: the switcher
lists what is running, the one in front first and the rest in the order they
were last in front, the desktop counting as one. Pressing F3 opens it on the
application before the one in front; while F3 is held the arrows or the
number keys choose and Escape puts it away; letting go brings the chosen
application to the front. A tap goes back to the previous application. It
draws as a row of icons on glass in the middle of the screen, the chosen one
on a lighter square with its name under the row.

### The Dock

The row of applications along the bottom of the screen, as on a Mac, an iPad
and an iPhone. Every platform with a pointer or touch shares it: PlatformUI
draws it, PlatformKit keeps what is in it, and each platform decides where it
goes and what choosing an entry does.

It holds the applications kept there first, Inlay first on Adaptive Desktop,
then a rule, then the applications that are open and not kept. On a desktop
each open application has a dot under its icon; on a touch screen the icons
are larger and there are no dots. The Dock sits on glass that floats above the
bottom edge.

The platform tells the compositor how tall a band along the bottom the Dock
takes, with `SetDock`. The pointer over it goes to the platform whatever has
focus, as it does over the system bar. In `Freeform` windows are laid out
above it and cannot be dragged under it, as on a Mac. In `Stack` and
`Exclusive` an application fills the screen to its bottom, as on an iPad: the
Dock shows over the home screen only, and while an application is in front
the platform keeps a thinner band for the home indicator, which goes home
when tapped. Going home puts every application on screen away with
`SetHidden`; choosing one in the Dock brings it back.

With a split in `Stack`, the two applications last opened share the screen,
the earlier on the left; one alone fills it.

Choosing an application:

- that is not running asks PID 1 to start it, with the same request and the
  same limits as the launcher;
- that is running brings its window to the front and gives it focus;
- that is running with its window minimized shows the window again first.

The platform knows which application a window is from PID 1. When PID 1 links
an application to the platform, it sends the application's name with the link,
to both ends. The name is not something the application says about itself.

PID 1 accepts only `Launch` from a platform. Every other request a platform
makes is refused.

### Stage Manager

F6 turns Stage Manager on and off, as its switch in a Mac's Control Center
does. The platform asks the compositor for its `stage` mode
([15](15-form-factors.md)). The application in front goes on the stage,
centred in the room beside the strip, below the bar and above the Dock. Every
other application shown waits in the strip down the leading edge as a small
picture of its window, the most recently in front at the top, four at most.

The compositor draws the pictures. Each is the window's whole buffer scaled
down, and the application is not configured to it, so it goes on drawing at
its own size. The platform draws each application's icon over the lower
leading corner of its picture with PlatformUI's `StageStrip`. Both place
through display-client's `stageSlot`, so the icon and the picture agree to the
pixel. A click on a picture is a click on a window without focus: the platform
is told, and it brings that application to the stage by granting it focus.

The window on the stage draws its own close, minimize and zoom buttons, as a
Mac's and an iPad's do in Stage Manager. On Adaptive Desktop minimize puts it in
the Dock. On Adaptive Mobile it goes to the strip and the window most recently in front
there takes the stage, as on an iPad. It leaves the screen only when nothing
else is shown. An application put away there, by going home or with its
yellow button, waits in the strip again once another comes to the stage.

The desktop's items are out of sight while Stage Manager is on, as a Mac's
are, and show while the desktop is in front, once it is clicked.

Turning Stage Manager off gives every window back the frame the person left it
at, as a Mac does. The compositor keeps that frame while another mode lays the
window out.

### The launcher

How something starts that is not running. A list of what is installed —
application bundles, `<Name>.app` in `/System/Applications` and
`/Applications`, as on a Mac ([12](12-apps.md)) — filtered by typing.

The list is the desktop's, the surface under every application, drawn by
the Desktop application, `/System/Applications/Desktop.app`, the way Finder
draws a Mac's. Launching is asking PID 1 to start it ([03](03-processes.md)),
as Finder asks launchd: the desktop sends the path of a bundle's executable over
the channel PID 1 gave it, and that is the whole protocol. PID 1 accepts only
`<Name>.app/Contents/MacOS/<Name>` under the two application folders, starts it
once, and links it to the display server, which admits it on top and focuses
it. Nothing more, because a desktop that could ask init to run arbitrary
programs would have undone the seal.

F4 gives the desktop focus whatever is in front. Escape quits an application.
When the window in front goes, however it went, the window behind it comes to
the front and takes the keyboard, the desktop when no window is left.

### The status area

What the machine wants to say when nothing else is speaking: the time, the
battery, whether it is doing something. Small, at the trailing end of the
system bar on platforms that draw one, summoned by a key on those that do not.

It shows the date and the time from the real-time clock, in UTC until there
are time zones; Focus while it is on, as a moon; and the battery as the power
service reads it, on a machine that has one. It stays on the lock screen, as a
Mac's menu bar extras and an iPhone's status icons do (PlatformUI
`StatusIcons`).

### The lock screen

What is on the output when the platform starts and when the machine wakes: the
platform's own surface, opaque and above every other, so nothing an
application draws shows until it is opened. It is PlatformUI's lock screen,
chosen like any other component by navigation model and distance: the time,
large, with the date above it, over the background picture, as a Mac's and an
iPhone's are.

It opens on any key, a click, or a swipe up from the bottom edge, and nothing
is asked: it is a cover, not a lock ([13](13-security-and-updates.md)). Opening
is one continuous motion, never a cut: the time and the date rise and fade, the
lock screen's picture loses its blur and settles into the background behind
the applications, and what was in front when it closed is in front again. On
a touch platform the lock screen follows the finger, and lets go to whichever
end it is nearer to. While it is shown the platform holds focus, so no key
reaches an application.

The status area stays on it, as the bar's trailing items do on a Mac's and an
iPhone's.

A person closes it again with the lock key: Pause, the key at the top
trailing corner of a PC keyboard, where a Mac's keyboard has its lock key.
The platform grabs it, as it grabs F3. Pressed with the lock screen open, it
closes the lock screen over the output at once and the platform holds the
keyboard, as at start. The application in front stays in front behind it, and
comes back when the lock screen opens again. The platform closes it the same
way when the output blanks for want of input, so the lock screen is what the
output wakes to.

### Notifications

An application wants to say something while not in front. It posts what it
has to say through KiraUI's `addNotification`, as UserNotifications posts on
Apple's platforms. AppKit sends it over the application's link to the
platform, as it sends the menus: a `Notify` record holding the title and the
body. A notification posted before the link is made waits for it.

The platform shows it with PlatformUI's `NotificationBanner`, chosen by the
interface in use. On Adaptive Desktop the banner comes in at the top trailing
corner below the bar, as a Mac's does, with up to three stacked, newest at the
top. On Adaptive Mobile it comes down at the top in the middle, at the iOS 27
kit's size: 377 by 66 points, a 24-point corner, a 38-point icon, the title in
15-point semibold with "now" beside it, and the body under it. A banner stays
five seconds. Clicking or tapping it brings the application that posted it to
the front, back from the Dock or from home if it was put away. While banners
are up the platform claims the part of the output they take with
`set_overlay` ([08](08-display-server.md)), so the click reaches the banner
and the window in front keeps the keyboard.

The display protocol's own `Notify` carries only an id and a priority, which
the compositor routes. What a notification says is the application's to tell
the platform, not the display server's.

A notification centre that keeps what was missed, grouping, and the lock
screen's list are still to come.

### Control Center

The switches a person reaches for without opening an application. It is
PlatformUI's `ControlCenter`, drawn from the iOS 27 kit's `Control Center -
iPad`: modules on a grid of 66-point units 10 points apart, four to a row. A
switch two units wide has its symbol on a 40-point circle, its name in
15-point medium and what it says under it at a third; a switch one unit square
has its symbol alone. Off, a module is glass; on, it is filled near white and
its symbol is blue, as the kit's toggles are.

On Adaptive Desktop its symbol stands at the trailing end of the bar, before
the clock, as a Mac's does, and a click on it hangs Control Center below the
bar at the trailing edge, on one piece of glass. On Adaptive Mobile a tap on
the trailing half of the status bar brings it down over the screen, dimmed to
the kit's 60 percent grey, with its modules 50 points in from the trailing
edge, as an iPad's comes down from its top right corner. While it is out the
platform holds the keyboard and the pointer, as it does for a menu; a click or
a tap off its modules, its symbol again, or Escape puts it away. Choosing a
switch leaves it out.

It holds these switches, each of which does what it says:

- **Focus.** On, a notification that arrives is not shown as a banner, as Do
  Not Disturb holds a Mac's and an iPad's back. The platform still takes it,
  and says so.
- **Stage Manager.** The switch F6 is.
- **Windowed Apps**, on Adaptive Mobile only, as an iPad's multitasking
  choice. On, the platform asks the compositor for its `freeform` mode, and
  applications open as windows that float free, each drawing its own close,
  minimize and zoom buttons. The platform answers their requests as Adaptive
  Desktop does: it grants a move or a resize, zoom fills the room below the
  status bar and above the band along the bottom, and minimize puts the window
  away until its application is chosen in the Dock. Stage Manager and Windowed
  Apps exclude each other; turning either off gives the stack back.
  Adaptive Desktop's windows always float free, so it has no such switch.

Display brightness and sound are modules on Apple's, and come when the machine
has a backlight and an audio mixer to set.

## Focus

The platform decides; the server enforces. When the platform says a surface is
focused, the server routes input there and nowhere else.

Rules worth stating before they are discovered:

- A newly launched application takes focus. Anything else feels broken.
- An application that exits gives focus back to the platform, not to whatever
  happens to be underneath.
- The switcher takes focus while it is open and gives it back when it closes.
- **Nothing can take focus by asking.** A client cannot steal it; only the platform
  grants it. That is one line in the server and it prevents an entire category
  of misbehaviour.

## What the platform is not

- Not a file manager. There is no general filesystem browsing on a sealed
  appliance; applications own their data ([12](12-apps.md)).
- Not a settings application. Settings are files ([05](05-storage-and-state.md))
  and the small number that need a UI can be an application like any other.
- Not a terminal. There is no shell ([01](01-principles.md)).

## Session lifecycle

There is one user and no login, so there is no session in the usual sense. What
there is:

- **Lock.** A machine that can be walked away from needs to be able to refuse
  input until something. With no authentication story, this is a real design
  question and not a checkbox — see [13](13-security-and-updates.md). Until
  there is a passphrase the platform draws a lock screen, below, which covers
  and does not refuse.
- **Idle.** Dim, then blank, then, eventually, suspend. MosaicDisplay dims
  and blanks the output on the times the platform sets with `set_idle`
  ([08](08-display-server.md)). Adaptive Desktop blanks it after ten minutes
  without input, a Mac's default, and Adaptive Mobile after two, an iPad's
  auto-lock default; both dim it ten seconds before, as an iPhone does. Media
  sets no times and never blanks, as a television's interface does not. When
  the output blanks the platform closes its lock screen. Anything past
  blanking needs power management the kernel does not currently have
  configured.
- **Shutdown.** The platform asks init, init does the sequence in
  [03](03-processes.md).

## Checkpoints

- [x] A background surface fills the display, drawn by a process that is not
      the display server: the desktop, Desktop.app on KiraUI.
- [x] The platform draws the system bar with KiraUI's system bar APIs, and the
      display server composites it over the application in front.
- [x] Applications are configured below the bar and draw no bar of their own.
- [x] The focused application's menus are in the bar, and choosing an item
      runs its command in the application, over the platform link.
- [x] The handover from splash to platform does not flash. MosaicDisplay
      keeps the splash on the screen until the platform's first frame has
      arrived (`the platform has drawn; the splash gives way`), and composes
      nothing before it. Watching the screen over VNC from power-on to the
      lock screen shows the firmware's picture and then the lock screen, with
      no dark picture between them.
- [x] A key opens a switcher listing what is running.
- [x] The Dock shows the kept and open applications along the bottom, and
      windows are laid out above it.
- [x] Choosing an application in the Dock starts it, brings it forward, or
      shows its minimized window again.
- [x] On Adaptive Mobile the Dock shows over the home screen, an application
      fills the screen with the home indicator over it, and tapping the
      indicator or pressing F4 goes home.
- [x] On Adaptive Mobile the status bar shows the time and the date over the
      home screen and the application in front, and the application is told
      the bar and the home indicator as its insets.
- [x] Applications open as freeform windows with traffic lights drawn by
      KiraUI, the same continuous corner all round, and a hairline edge.
- [x] A window casts its own shadow, deep in front and shallow behind, drawn
      by KiraUI in the margin its buffers reach into (`set_margin`).
- [x] Dragging a window's title bar moves it, once the platform grants the
      move.
- [x] Dragging a window's edge or corner resizes it, once the platform
      grants the resize, with the Mac's resize cursor over the edge.
- [x] A window's traffic lights do what they say, on both adaptive
      platforms. On a 1280x800 output Notes opens at 143,116; a click on the
      green light logs `zoomed a window` and the window redraws at once to
      the room between the bar and the Dock; a second click puts it back at
      853 wide; the yellow light logs `minimized a window` and the window
      behind takes focus; choosing Notes in the Dock shows it again where it
      was; the red light quits it and brings the window behind forward.
- [x] On Adaptive Mobile, Control Center's Windowed Apps switch puts the
      compositor in freeform mode (`the arrangement changed`, windowed), Notes
      opens as a window with its traffic lights, a drag on its title bar
      moves it, and a window zoomed, minimized and chosen again in the Dock
      comes back still zoomed. A window keeps the frame it was left at while
      windows are freeform, so it does not move when the Dock comes and goes.
- [x] A launcher lists what is installed, from the application bundles.
- [x] Choosing an entry starts it, and it takes focus.
- [x] Closing it returns focus to what was behind it, and F4 to the desktop.
- [x] A client that asks for focus does not get it. Only the platform's
      session may grant focus; the multi boot has both applications ask, and
      asserts `refused focus to an application that asked for it|surface: 2`
      and that the key then reaches client 3 alone.
- [x] An application's notification shows as a banner, and choosing it
      brings the application forward. Clock's one-minute timer, started and
      then left behind Notes, ends behind it (`a timer ended`); the platform
      shows its banner at the top trailing corner (`a notification banner
      appeared`) and claims the banner's part of the output with
      `set_overlay`; a click on the banner logs `a notification brought its
      application forward`, and Clock is in front with its menus on the bar.
- [x] Control Center opens from its symbol on the bar, and its Focus and
      Stage Manager switches do what they say. Clicking the symbol on a
      1280x800 output logs `Control Center opened`; clicking Focus turns it
      blue and reads "On" (`Focus changed`); clicking Stage Manager turns its
      symbol blue and puts the compositor in Stage mode (`Stage Manager
      changed`); a click off the modules logs `Control Center closed`.
- [x] F6 turns Stage Manager on, with the window in front on the stage and
      the others in the strip, and off again, with each window back where it
      was left. The multi boot asserts both layouts on `the mode changed`.
- [x] The platform starts on its lock screen, which opens on a key, a click or
      a swipe in one continuous motion into what was in front.
- [x] Left alone, the output dims and then blanks on the times the platform
      set, and the lock screen closes as it blanks; the key that wakes it
      reaches no client. `-services-mobile` boots with twenty seconds of
      display sleep and asserts `the output changed for want of input` as
      dimmed, blanked and awake, from MosaicDisplay and the platform both.
- [x] The time is on screen and correct, in the time zone chosen in Settings'
      Date & Time (LibTessera `System/TimeZone.kira`, the tz database at
      `System/Library/ZoneInfo`).

import QtQuick
import QtQuick.Window
import QtQuick3D
import QtQuick3D.AssetUtils
import QtCore

Window {
    id: root

    width: 340
    height: 380

    visible: true
    color: "transparent"

    flags: Qt.FramelessWindowHint |
           Qt.WindowStaysOnTopHint |
           Qt.Tool


    // ========================================================
    // CONFIG
    // ========================================================
    property string assetPath:
        Qt.resolvedUrl(
            "assets/Meshy_AI_Robo_Cat_Orb_0921143520_texture.glb"
        )
    property real modelScale: 30


    // ========================================================
    // POSE CHANNELS
    // ========================================================
    property real bob: 0
    property real pitch: 0
    property real yaw: 0
    property real roll: 0
    property real pulse: 1.0
    property real sideMove: 0
    property real jumpY: 0

    property real spinPitch: 0
    property real spinYaw: 0
    property real spinRoll: 0

    property real trackYaw: 0
    property real trackPitch: 0
    property real blink: 0


    // ========================================================
    // DERIVED SCALE (squash & stretch)
    // ========================================================
    readonly property real _jumpStretch: Math.max(0, jumpY) / 100

    readonly property real scaleX:
        pulse * (1 - _jumpStretch * 0.5) * (1 - blink * 0.05)
    readonly property real scaleY:
        pulse * (1 + _jumpStretch * 1.0) * (1 - blink * 0.15)
    readonly property real scaleZ:
        pulse * (1 - _jumpStretch * 0.5) * (1 - blink * 0.05)


    // ========================================================
    // STATE
    // ========================================================
    property string currentState: "idle"
    property bool advancedBusy: false
    property bool chatVisible: false
    property bool dragging: false

    property int thinkDots: 0

    // --------------------------------------------------------
    // Safe reference to the C++ backend (context property).
    // Using a root-level alias avoids scoping issues inside
    // Repeater delegates.
    // --------------------------------------------------------
    readonly property var backend: (typeof maxBackend !== "undefined")
                                  ? maxBackend
                                  : null


    // ========================================================
    // SMOOTHED MOUSE TRACKING
    // ========================================================
    Behavior on trackYaw   { SmoothedAnimation { velocity: 400 } }
    Behavior on trackPitch { SmoothedAnimation { velocity: 400 } }


    // ========================================================
    // WINDOW POSITION PERSISTENCE
    // ========================================================
    Settings {
        id: appSettings
        category: "MaxWindow"
        property alias x: root.x
        property alias y: root.y
        property bool firstRun: true
    }


    // ========================================================
    // 3D SCENE
    // ========================================================
    View3D {
        id: view
        x: 0
        y: 0
        width: parent.width
        height: 260
        camera: camera

        environment: SceneEnvironment {
            clearColor: "transparent"
            backgroundMode: SceneEnvironment.Transparent
        }

        PerspectiveCamera {
            id: camera
            position: Qt.vector3d(0, 0, 220)
            fieldOfView: 30
        }

        DirectionalLight {
            eulerRotation: Qt.vector3d(-35, -25, 0)
            brightness: 1.5
        }
        DirectionalLight {
            eulerRotation: Qt.vector3d(25, 150, 0)
            brightness: 0.8
        }

        RuntimeLoader {
            id: robo
            source: root.assetPath

            scale: Qt.vector3d(
                root.modelScale * root.scaleX,
                root.modelScale * root.scaleY,
                root.modelScale * root.scaleZ
            )

            eulerRotation: Qt.vector3d(
                root.pitch + root.spinPitch + root.trackPitch,
                root.yaw   + root.spinYaw   + root.trackYaw,
                root.roll  + root.spinRoll
            )

            position: Qt.vector3d(
                -((bounds.maximum.x + bounds.minimum.x) / 2) * root.modelScale
                    + root.sideMove,
                -((bounds.maximum.y + bounds.minimum.y) / 2) * root.modelScale
                    + root.bob + root.jumpY,
                -((bounds.maximum.z + bounds.minimum.z) / 2) * root.modelScale
            )
        }
    }


    // ========================================================
    // SHADOW BLOB (soft ground cue, keeps jumps grounded)
    // ========================================================
    Item {
        id: shadowLayer
        z: 1
        anchors.fill: view
        enabled: false

        Rectangle {
            width: 90
            height: 16
            radius: height / 2
            color: "#66000000"
            anchors.horizontalCenter: parent.horizontalCenter
            y: parent.height - 34 + root.bob * 0.4
            opacity: Math.max(0, 0.28 - root.jumpY / 110)
            scale:   Math.max(0.4, 1 - root.jumpY / 140)
        }
    }


    // ========================================================
    // SPARKLE PARTICLES
    // ========================================================
    Item {
        id: sparkleLayer
        z: 2
        anchors.fill: view
        enabled: false

        function burst(count, color, originX, originY) {
            for (var i = 0; i < count; i++) {
                var angle = Math.random() * Math.PI * 2
                var speed = 50 + Math.random() * 120
                var tx = originX + Math.cos(angle) * speed
                var ty = originY + Math.sin(angle) * speed - 40
                sparkleComponent.createObject(sparkleLayer, {
                    "x": originX,
                    "y": originY,
                    "sparkColor": color,
                    "targetX": tx,
                    "targetY": ty
                })
            }
        }

        function burstAtModel(count, color) {
            burst(count, color, view.width / 2, view.height * 0.45)
        }
    }

    Component {
        id: sparkleComponent

        Rectangle {
            id: sparkleItem
            property color sparkColor: "#FFDD88"
            property real  targetX: 0
            property real  targetY: 0

            width: 5 + Math.random() * 4
            height: width
            radius: width / 2
            color: sparkColor
            opacity: 0

            ParallelAnimation {
                running: true
                NumberAnimation {
                    target: sparkleItem; property: "x"
                    to: sparkleItem.targetX
                    duration: 900; easing.type: Easing.OutCubic
                }
                NumberAnimation {
                    target: sparkleItem; property: "y"
                    to: sparkleItem.targetY
                    duration: 900; easing.type: Easing.OutCubic
                }
                NumberAnimation {
                    target: sparkleItem; property: "opacity"
                    from: 1; to: 0
                    duration: 900
                }
                NumberAnimation {
                    target: sparkleItem; property: "scale"
                    from: 1.3; to: 0.2
                    duration: 900
                }
            }

            Timer {
                interval: 950
                running: true
                onTriggered: sparkleItem.destroy()
            }
        }
    }


    // ========================================================
    // IDLE ANIMATIONS
    // ========================================================
    SequentialAnimation {
        id: idleFloat
        loops: Animation.Infinite
        NumberAnimation {
            target: root; property: "bob"
            from: -4; to: 4
            duration: 2200; easing.type: Easing.InOutSine
        }
        NumberAnimation {
            target: root; property: "bob"
            from: 4; to: -4
            duration: 2200; easing.type: Easing.InOutSine
        }
    }

    SequentialAnimation {
        id: idleYaw
        loops: Animation.Infinite
        NumberAnimation {
            target: root; property: "yaw"
            from: -7; to: 7
            duration: 3600; easing.type: Easing.InOutSine
        }
        NumberAnimation {
            target: root; property: "yaw"
            from: 7; to: -7
            duration: 3600; easing.type: Easing.InOutSine
        }
    }

    SequentialAnimation {
        id: idleTilt
        loops: Animation.Infinite
        PauseAnimation { duration: 2200 }
        NumberAnimation {
            target: root; property: "roll"
            from: -3; to: 3
            duration: 1100; easing.type: Easing.InOutSine
        }
        NumberAnimation {
            target: root; property: "roll"
            from: 3; to: -3
            duration: 1100; easing.type: Easing.InOutSine
        }
        PauseAnimation { duration: 2200 }
    }

    // Blink cycle
    SequentialAnimation {
        id: blinkAnim
        NumberAnimation {
            target: root; property: "blink"
            to: 1; duration: 70
        }
        NumberAnimation {
            target: root; property: "blink"
            to: 0; duration: 130
        }
    }

    Timer {
        id: blinkTimer
        interval: 2500 + Math.random() * 3500
        running: root.currentState === "idle"
        repeat: true
        onTriggered: {
            blinkAnim.restart()
            interval = 2500 + Math.random() * 3500
        }
    }


    // ========================================================
    // THINKING
    // ========================================================
    SequentialAnimation {
        id: thinkingYaw
        loops: Animation.Infinite
        NumberAnimation {
            target: root; property: "yaw"
            from: -15; to: 15
            duration: 900; easing.type: Easing.InOutSine
        }
        NumberAnimation {
            target: root; property: "yaw"
            from: 15; to: -15
            duration: 900; easing.type: Easing.InOutSine
        }
    }

    SequentialAnimation {
        id: thinkingBob
        loops: Animation.Infinite
        NumberAnimation {
            target: root; property: "bob"
            from: -6; to: 6
            duration: 700; easing.type: Easing.InOutSine
        }
        NumberAnimation {
            target: root; property: "bob"
            from: 6; to: -6
            duration: 700; easing.type: Easing.InOutSine
        }
    }

    SequentialAnimation {
        id: thinkingTilt
        loops: Animation.Infinite
        NumberAnimation {
            target: root; property: "roll"
            from: -6; to: 6
            duration: 1400; easing.type: Easing.InOutSine
        }
        NumberAnimation {
            target: root; property: "roll"
            from: 6; to: -6
            duration: 1400; easing.type: Easing.InOutSine
        }
    }

    Timer {
        id: thinkDotTimer
        interval: 350
        repeat: true
        running: root.currentState === "thinking"
        onTriggered: root.thinkDots = (root.thinkDots + 1) % 4
    }


    // ========================================================
    // SPEAKING
    // ========================================================
    SequentialAnimation {
        id: speakingPulse
        loops: Animation.Infinite
        NumberAnimation {
            target: root; property: "pulse"
            from: 1.0; to: 1.045
            duration: 350; easing.type: Easing.InOutSine
        }
        NumberAnimation {
            target: root; property: "pulse"
            from: 1.045; to: 1.0
            duration: 350; easing.type: Easing.InOutSine
        }
    }

    SequentialAnimation {
        id: speakingMovement
        loops: Animation.Infinite
        NumberAnimation {
            target: root; property: "bob"
            from: -3; to: 4
            duration: 400; easing.type: Easing.InOutSine
        }
        NumberAnimation {
            target: root; property: "bob"
            from: 4; to: -3
            duration: 400; easing.type: Easing.InOutSine
        }
    }

    SequentialAnimation {
        id: speakingRoll
        loops: Animation.Infinite
        NumberAnimation {
            target: root; property: "roll"
            from: -4; to: 4
            duration: 600; easing.type: Easing.InOutSine
        }
        NumberAnimation {
            target: root; property: "roll"
            from: 4; to: -4
            duration: 600; easing.type: Easing.InOutSine
        }
    }


    // ========================================================
    // HAPPY
    // ========================================================
    SequentialAnimation {
        id: happyAnimation
        loops: 2
        onStarted: sparkleLayer.burstAtModel(20, "#FFDD66")

        ParallelAnimation {
            NumberAnimation {
                target: root; property: "jumpY"
                from: 0; to: 22
                duration: 260; easing.type: Easing.OutQuad
            }
            NumberAnimation {
                target: root; property: "spinYaw"
                from: 0; to: 360
                duration: 520; easing.type: Easing.InOutCubic
            }
            NumberAnimation {
                target: root; property: "pulse"
                from: 1; to: 1.08
                duration: 260
            }
        }
        ParallelAnimation {
            NumberAnimation {
                target: root; property: "jumpY"
                from: 22; to: 0
                duration: 380; easing.type: Easing.OutBounce
            }
            NumberAnimation {
                target: root; property: "pulse"
                from: 1.08; to: 1
                duration: 380
            }
        }

        onStopped: root.spinYaw = 0
    }


    // ========================================================
    // ERROR
    // ========================================================
    SequentialAnimation {
        id: errorAnimation
        loops: 3
        NumberAnimation {
            target: root; property: "yaw"
            from: -10; to: 10
            duration: 90; easing.type: Easing.InOutSine
        }
        NumberAnimation {
            target: root; property: "yaw"
            from: 10; to: -10
            duration: 90; easing.type: Easing.InOutSine
        }
        NumberAnimation {
            target: root; property: "pitch"
            from: -4; to: 4
            duration: 90
        }
        NumberAnimation {
            target: root; property: "pitch"
            from: 4; to: -4
            duration: 90
        }
    }


    // ========================================================
    // LISTENING
    // ========================================================
    SequentialAnimation {
        id: listeningAnimation
        loops: Animation.Infinite
        NumberAnimation {
            target: root; property: "roll"
            from: -6; to: 6
            duration: 900; easing.type: Easing.InOutSine
        }
        NumberAnimation {
            target: root; property: "roll"
            from: 6; to: -6
            duration: 900; easing.type: Easing.InOutSine
        }
    }


    // ========================================================
    // SLEEPY
    // ========================================================
    SequentialAnimation {
        id: sleepyBob
        loops: Animation.Infinite
        NumberAnimation {
            target: root; property: "bob"
            from: -2; to: 3
            duration: 3200; easing.type: Easing.InOutSine
        }
        NumberAnimation {
            target: root; property: "bob"
            from: 3; to: -2
            duration: 3200; easing.type: Easing.InOutSine
        }
    }

    SequentialAnimation {
        id: sleepyDroop
        loops: Animation.Infinite
        NumberAnimation {
            target: root; property: "pitch"
            from: 0; to: 12
            duration: 2400; easing.type: Easing.InOutSine
        }
        NumberAnimation {
            target: root; property: "pitch"
            from: 12; to: 0
            duration: 2400; easing.type: Easing.InOutSine
        }
    }


    // ========================================================
    // EXCITED
    // ========================================================
    SequentialAnimation {
        id: excitedBob
        loops: Animation.Infinite
        NumberAnimation {
            target: root; property: "bob"
            from: -5; to: 8
            duration: 220; easing.type: Easing.InOutSine
        }
        NumberAnimation {
            target: root; property: "bob"
            from: 8; to: -5
            duration: 220; easing.type: Easing.InOutSine
        }
    }

    SequentialAnimation {
        id: excitedSpin
        loops: Animation.Infinite
        NumberAnimation {
            target: root; property: "spinYaw"
            from: 0; to: 360
            duration: 900; easing.type: Easing.Linear
        }
    }


    // ========================================================
    // CURIOUS
    // ========================================================
    SequentialAnimation {
        id: curiousLook
        loops: Animation.Infinite
        NumberAnimation {
            target: root; property: "spinYaw"
            to: 25; duration: 700; easing.type: Easing.OutCubic
        }
        PauseAnimation { duration: 700 }
        NumberAnimation {
            target: root; property: "spinYaw"
            to: -25; duration: 1000; easing.type: Easing.InOutCubic
        }
        PauseAnimation { duration: 700 }
        NumberAnimation {
            target: root; property: "spinYaw"
            to: 0; duration: 600; easing.type: Easing.InOutCubic
        }
    }


    // ========================================================
    // CELEBRATING
    // ========================================================
    SequentialAnimation {
        id: celebratingAnim
        loops: 2
        onStarted: sparkleLayer.burstAtModel(28, "#FFD700")

        ParallelAnimation {
            NumberAnimation {
                target: root; property: "spinRoll"
                from: 0; to: 360
                duration: 900; easing.type: Easing.InOutCubic
            }
            NumberAnimation {
                target: root; property: "jumpY"
                from: 0; to: 18
                duration: 300; easing.type: Easing.OutCubic
            }
        }
        NumberAnimation {
            target: root; property: "jumpY"
            from: 18; to: 0
            duration: 500; easing.type: Easing.OutBounce
        }

        onStopped: root.spinRoll = 0
    }


    // ========================================================
    // RANDOM IDLE ANIMATIONS
    // ========================================================
    SequentialAnimation {
        id: rndSpin360X
        onStarted: root.advancedBusy = true
        onStopped: {
            root.spinPitch = 0
            root.advancedBusy = false
        }
        NumberAnimation {
            target: root; property: "spinPitch"
            from: 0; to: 360
            duration: 900; easing.type: Easing.InOutCubic
        }
    }

    SequentialAnimation {
        id: rndSpin360Y
        onStarted: root.advancedBusy = true
        onStopped: {
            root.spinYaw = 0
            root.advancedBusy = false
        }
        NumberAnimation {
            target: root; property: "spinYaw"
            from: 0; to: 360
            duration: 900; easing.type: Easing.InOutCubic
        }
    }

    SequentialAnimation {
        id: rndBarrelRoll
        onStarted: root.advancedBusy = true
        onStopped: {
            root.spinRoll = 0
            root.advancedBusy = false
        }
        NumberAnimation {
            target: root; property: "spinRoll"
            from: 0; to: 360
            duration: 800; easing.type: Easing.InOutCubic
        }
    }

    SequentialAnimation {
        id: rndDiagonalTilt
        onStarted: root.advancedBusy = true
        onStopped: root.advancedBusy = false

        ParallelAnimation {
            NumberAnimation {
                target: root; property: "spinPitch"
                to: 45; duration: 450; easing.type: Easing.OutCubic
            }
            NumberAnimation {
                target: root; property: "spinYaw"
                to: 45; duration: 450; easing.type: Easing.OutCubic
            }
            NumberAnimation {
                target: root; property: "jumpY"
                to: 8; duration: 450; easing.type: Easing.OutCubic
            }
        }
        PauseAnimation { duration: 600 }
        ParallelAnimation {
            NumberAnimation {
                target: root; property: "spinPitch"
                to: 0; duration: 450; easing.type: Easing.OutBack
            }
            NumberAnimation {
                target: root; property: "spinYaw"
                to: 0; duration: 450; easing.type: Easing.OutBack
            }
            NumberAnimation {
                target: root; property: "jumpY"
                to: 0; duration: 450; easing.type: Easing.InOutCubic
            }
        }
    }

    SequentialAnimation {
        id: rndNod
        loops: 2
        onStarted: root.advancedBusy = true
        onStopped: root.advancedBusy = false

        NumberAnimation {
            target: root; property: "spinPitch"
            to: 18; duration: 180; easing.type: Easing.OutCubic
        }
        NumberAnimation {
            target: root; property: "spinPitch"
            to: -6; duration: 180; easing.type: Easing.InCubic
        }
        NumberAnimation {
            target: root; property: "spinPitch"
            to: 0; duration: 140; easing.type: Easing.InOutCubic
        }
    }

    SequentialAnimation {
        id: rndLookAround
        onStarted: root.advancedBusy = true
        onStopped: root.advancedBusy = false

        NumberAnimation {
            target: root; property: "spinYaw"
            to: 35; duration: 500; easing.type: Easing.OutCubic
        }
        PauseAnimation { duration: 500 }
        NumberAnimation {
            target: root; property: "spinYaw"
            to: -35; duration: 800; easing.type: Easing.InOutCubic
        }
        PauseAnimation { duration: 500 }
        NumberAnimation {
            target: root; property: "spinYaw"
            to: 0; duration: 500; easing.type: Easing.InOutCubic
        }
    }

    SequentialAnimation {
        id: rndBounce
        onStarted: root.advancedBusy = true
        onStopped: root.advancedBusy = false

        NumberAnimation {
            target: root; property: "jumpY"
            to: -8; duration: 180; easing.type: Easing.InQuad
        }
        NumberAnimation {
            target: root; property: "jumpY"
            to: 30; duration: 260; easing.type: Easing.OutQuad
        }
        NumberAnimation {
            target: root; property: "jumpY"
            to: 0; duration: 520; easing.type: Easing.OutBounce
        }
    }

    SequentialAnimation {
        id: rndWiggle
        loops: 4
        onStarted: root.advancedBusy = true
        onStopped: {
            root.spinRoll = 0
            root.spinYaw = 0
            root.advancedBusy = false
        }

        ParallelAnimation {
            NumberAnimation {
                target: root; property: "spinRoll"
                to: 12; duration: 90; easing.type: Easing.InOutSine
            }
            NumberAnimation {
                target: root; property: "spinYaw"
                to: 8; duration: 90; easing.type: Easing.InOutSine
            }
        }
        ParallelAnimation {
            NumberAnimation {
                target: root; property: "spinRoll"
                to: -12; duration: 90; easing.type: Easing.InOutSine
            }
            NumberAnimation {
                target: root; property: "spinYaw"
                to: -8; duration: 90; easing.type: Easing.InOutSine
            }
        }
    }

    SequentialAnimation {
        id: rndSneeze
        onStarted: root.advancedBusy = true
        onStopped: {
            root.spinPitch = 0
            root.jumpY = 0
            root.pulse = 1
            root.advancedBusy = false
        }

        ParallelAnimation {
            NumberAnimation {
                target: root; property: "spinPitch"
                to: -8; duration: 300; easing.type: Easing.OutCubic
            }
            NumberAnimation {
                target: root; property: "jumpY"
                to: -5; duration: 300; easing.type: Easing.OutCubic
            }
        }
        ParallelAnimation {
            NumberAnimation {
                target: root; property: "spinPitch"
                to: 25; duration: 100; easing.type: Easing.OutCubic
            }
            NumberAnimation {
                target: root; property: "jumpY"
                to: 12; duration: 100; easing.type: Easing.OutCubic
            }
            NumberAnimation {
                target: root; property: "pulse"
                to: 1.14; duration: 100
            }
        }
        ParallelAnimation {
            NumberAnimation {
                target: root; property: "spinPitch"
                to: 0; duration: 500; easing.type: Easing.OutBack
            }
            NumberAnimation {
                target: root; property: "jumpY"
                to: 0; duration: 500; easing.type: Easing.OutBounce
            }
            NumberAnimation {
                target: root; property: "pulse"
                to: 1; duration: 500
            }
        }
    }

    SequentialAnimation {
        id: rndStretch
        onStarted: root.advancedBusy = true
        onStopped: {
            root.spinPitch = 0
            root.jumpY = 0
            root.pulse = 1
            root.advancedBusy = false
        }

        ParallelAnimation {
            NumberAnimation {
                target: root; property: "spinPitch"
                to: -12; duration: 600; easing.type: Easing.OutCubic
            }
            NumberAnimation {
                target: root; property: "jumpY"
                to: 6; duration: 600; easing.type: Easing.OutCubic
            }
            NumberAnimation {
                target: root; property: "pulse"
                to: 1.08; duration: 600; easing.type: Easing.OutCubic
            }
        }
        PauseAnimation { duration: 400 }
        ParallelAnimation {
            NumberAnimation {
                target: root; property: "spinPitch"
                to: 0; duration: 800; easing.type: Easing.InOutCubic
            }
            NumberAnimation {
                target: root; property: "jumpY"
                to: 0; duration: 800; easing.type: Easing.InOutCubic
            }
            NumberAnimation {
                target: root; property: "pulse"
                to: 1; duration: 800; easing.type: Easing.InOutCubic
            }
        }
    }

    SequentialAnimation {
        id: rndAttention
        onStarted: root.advancedBusy = true
        onStopped: root.advancedBusy = false

        ParallelAnimation {
            NumberAnimation {
                target: root; property: "spinYaw"
                to: -22; duration: 450; easing.type: Easing.OutCubic
            }
            NumberAnimation {
                target: root; property: "spinPitch"
                to: -6; duration: 450; easing.type: Easing.OutCubic
            }
        }
        PauseAnimation { duration: 900 }
        ParallelAnimation {
            NumberAnimation {
                target: root; property: "spinYaw"
                to: 0; duration: 550; easing.type: Easing.InOutCubic
            }
            NumberAnimation {
                target: root; property: "spinPitch"
                to: 0; duration: 550; easing.type: Easing.InOutCubic
            }
        }
    }

    // ---- FLIP (full 360 somersault on X while airborne) ----
    SequentialAnimation {
        id: rndFlip
        onStarted: {
            root.advancedBusy = true
            sparkleLayer.burstAtModel(12, "#AADDFF")
        }
        onStopped: {
            root.spinPitch = 0
            root.jumpY = 0
            root.advancedBusy = false
        }

        ParallelAnimation {
            NumberAnimation {
                target: root; property: "spinPitch"
                from: 0; to: 360
                duration: 750; easing.type: Easing.InOutCubic
            }
            SequentialAnimation {
                NumberAnimation {
                    target: root; property: "jumpY"
                    to: 42; duration: 375; easing.type: Easing.OutQuad
                }
                NumberAnimation {
                    target: root; property: "jumpY"
                    to: 0; duration: 375; easing.type: Easing.InQuad
                }
            }
        }
    }

    // ---- DANCE (wiggle + spin + hop) ----
    SequentialAnimation {
        id: rndDance
        loops: 3
        onStarted: root.advancedBusy = true
        onStopped: {
            root.spinYaw = 0
            root.spinRoll = 0
            root.bob = 0
            root.advancedBusy = false
        }

        ParallelAnimation {
            NumberAnimation {
                target: root; property: "spinYaw"
                to: 30; duration: 200; easing.type: Easing.InOutSine
            }
            NumberAnimation {
                target: root; property: "spinRoll"
                to: 18; duration: 200; easing.type: Easing.InOutSine
            }
            NumberAnimation {
                target: root; property: "bob"
                to: 12; duration: 200; easing.type: Easing.OutQuad
            }
        }
        ParallelAnimation {
            NumberAnimation {
                target: root; property: "spinYaw"
                to: -30; duration: 200; easing.type: Easing.InOutSine
            }
            NumberAnimation {
                target: root; property: "spinRoll"
                to: -18; duration: 200; easing.type: Easing.InOutSine
            }
            NumberAnimation {
                target: root; property: "bob"
                to: 0; duration: 200; easing.type: Easing.InQuad
            }
        }
    }


    // ========================================================
    // RANDOM IDLE SCHEDULER
    // ========================================================
    Timer {
        id: randomIdleTimer
        repeat: true
        running: root.currentState === "idle"
        interval: 4000

        onTriggered: {
            if (!root.advancedBusy && !root.dragging)
                root.playRandomIdle()
            randomIdleTimer.interval = 3500 + Math.random() * 5500
        }
    }

    function playRandomIdle() {
        var r = Math.random()
        if (r < 0.10)      rndSpin360X.start()
        else if (r < 0.20) rndSpin360Y.start()
        else if (r < 0.29) rndBarrelRoll.start()
        else if (r < 0.39) rndDiagonalTilt.start()
        else if (r < 0.50) rndNod.start()
        else if (r < 0.61) rndLookAround.start()
        else if (r < 0.70) rndBounce.start()
        else if (r < 0.77) rndWiggle.start()
        else if (r < 0.84) rndStretch.start()
        else if (r < 0.91) rndSneeze.start()
        else if (r < 0.96) rndFlip.start()
        else               rndDance.start()
    }


    // ========================================================
    // NAMED ANIMATION PLAYER (called from backend)
    // ========================================================
    function playNamedAnimation(name) {
        if (root.advancedBusy) {
            root.advancedBusy = false
        }

        switch (name) {
        case "flip":         rndFlip.start();         break
        case "spin360":
        case "spin":
        case "rotate":       rndSpin360Y.start();     break
        case "spin360x":     rndSpin360X.start();     break
        case "barrel":
        case "roll":         rndBarrelRoll.start();   break
        case "diagonal":
        case "tilt":         rndDiagonalTilt.start(); break
        case "jump":
        case "bounce":       rndBounce.start();       break
        case "nod":          rndNod.start();          break
        case "wiggle":       rndWiggle.start();       break
        case "sneeze":       rndSneeze.start();       break
        case "stretch":      rndStretch.start();      break
        case "look":         rndLookAround.start();   break
        case "attention":    rndAttention.start();    break
        case "dance":        rndDance.start();        break
        case "celebrate":    celebratingAnim.start(); break
        case "happy":        happyAnimation.start();  break
        default:
            console.log("Unknown animation:", name)
        }
    }


    // ========================================================
    // BACKEND HOOK
    // ========================================================
    Connections {
        target: root.backend

        function onStateChanged() {
            if (root.backend) root.updateState(root.backend.state)
        }

        function onMoveToTopRightRequested() {
            root.moveToTopRight()
        }

        function onToggleVisibilityRequested() {
            root.visible = !root.visible
            if (root.visible) root.moveToTopRight()
        }

        function onAnimationRequested(name) {
            root.playNamedAnimation(name)
        }
    }


    function stopAnimations() {
        idleFloat.stop();  idleYaw.stop();  idleTilt.stop()
        thinkingYaw.stop(); thinkingBob.stop(); thinkingTilt.stop()
        speakingPulse.stop(); speakingMovement.stop(); speakingRoll.stop()
        happyAnimation.stop()
        errorAnimation.stop()
        listeningAnimation.stop()
        sleepyBob.stop();  sleepyDroop.stop()
        excitedBob.stop(); excitedSpin.stop()
        curiousLook.stop()
        celebratingAnim.stop()
        rndSpin360X.stop(); rndSpin360Y.stop(); rndBarrelRoll.stop()
        rndDiagonalTilt.stop(); rndNod.stop()
        rndLookAround.stop(); rndBounce.stop(); rndWiggle.stop()
        rndSneeze.stop(); rndStretch.stop(); rndAttention.stop()
        rndFlip.stop(); rndDance.stop()
        blinkAnim.stop()
        root.advancedBusy = false
    }

    function resetPose() {
        root.bob = 0
        root.pitch = 0
        root.yaw = 0
        root.roll = 0
        root.pulse = 1.0
        root.sideMove = 0
        root.jumpY = 0
        root.spinPitch = 0
        root.spinYaw = 0
        root.spinRoll = 0
        root.trackPitch = 0
        root.trackYaw = 0
        root.blink = 0
    }

    function updateState(state) {
        root.currentState = state
        stopAnimations()
        resetPose()

        switch (state) {

        case "thinking":
            thinkingYaw.start(); thinkingBob.start(); thinkingTilt.start()
            thinkDotTimer.restart()
            break

        case "speaking":
            speakingPulse.start(); speakingMovement.start(); speakingRoll.start()
            speakTimer.restart()
            break

        case "happy":
            happyAnimation.start()
            happyTimer.restart()
            break

        case "error":
            errorAnimation.start()
            break

        case "listening":
            listeningAnimation.start()
            break

        case "sleepy":
            sleepyBob.start(); sleepyDroop.start()
            break

        case "excited":
            excitedBob.start(); excitedSpin.start()
            break

        case "curious":
            curiousLook.start()
            break

        case "celebrating":
            celebratingAnim.start()
            happyTimer.restart()
            break

        default: // idle
            idleFloat.start(); idleYaw.start(); idleTilt.start()
            randomIdleTimer.interval = 2500
            randomIdleTimer.restart()
        }
    }


    // ========================================================
    // WINDOW HELPERS
    // ========================================================
    function moveToTopRight() {
        var scr = root.screen
        root.x = scr.width - root.width - 20
        root.y = 20
    }

    function snapToEdge() {
        var snapDist = 40
        var scr = root.screen
        if (Math.abs(root.x) < snapDist)
            root.x = 0
        else if (Math.abs(root.x + root.width - scr.width) < snapDist)
            root.x = scr.width - root.width
        if (Math.abs(root.y) < snapDist)
            root.y = 0
        else if (Math.abs(root.y + root.height - scr.height) < snapDist)
            root.y = scr.height - root.height
    }


    // ========================================================
    // MOUSE AREA
    // ========================================================
    MouseArea {
        id: maxMouseArea
        x: 0
        y: 0
        width: parent.width
        height: view.height
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        hoverEnabled: true

        property real startMouseX: 0
        property real startMouseY: 0
        property real startWindowX: 0
        property real startWindowY: 0
        property real lastMouseX: 0
        property real lastMouseY: 0
        property real dragDistance: 0

        onPressed: function(mouse) {
            startMouseX = mouse.x
            startMouseY = mouse.y
            startWindowX = root.x
            startWindowY = root.y
            lastMouseX = mouse.x
            lastMouseY = mouse.y
            dragDistance = 0
            root.dragging = true
        }

        onPositionChanged: function(mouse) {
            if (pressed) {
                root.x = startWindowX + (mouse.x - startMouseX)
                root.y = startWindowY + (mouse.y - startMouseY)
                dragDistance += Math.abs(mouse.x - lastMouseX)
                              + Math.abs(mouse.y - lastMouseY)
                lastMouseX = mouse.x
                lastMouseY = mouse.y
            } else if (hoverEnabled && !root.advancedBusy
                       && root.currentState === "idle") {
                var cx = width / 2
                var cy = height / 2
                var dx = (mouse.x - cx) / cx
                var dy = (mouse.y - cy) / cy
                root.trackYaw = Math.max(-1, Math.min(1, dx)) * 18
                root.trackPitch = Math.max(-1, Math.min(1, dy)) * 10
            }
        }

        onReleased: function(mouse) {
            root.dragging = false
            if (dragDistance > 120 && !root.advancedBusy) {
                if (Math.random() < 0.5)
                    rndSpin360Y.start()
            }
            snapToEdge()
        }

        onExited: {
            root.trackYaw = 0
            root.trackPitch = 0
        }

        onClicked: function(mouse) {
            if (mouse.button === Qt.RightButton) {
                contextMenu.showAt(mouse.x, mouse.y)
                return
            }
            if (contextMenu.visible) {
                contextMenu.visible = false
                return
            }
            // Left-click → squeak + small pulse reaction
            if (root.backend) root.backend.pokeMax()
            root.pulse = 1.08
            pokePulseTimer.restart()
        }
    }


    // ========================================================
    // CONTEXT MENU
    // ========================================================
    Rectangle {
        id: contextMenu
        visible: false
        z: 100
        width: 170
        height: menuCol.implicitHeight + 8
        color: "#CC1A1A1A"
        border.color: "#444444"
        border.width: 1
        radius: 8

        function showAt(mx, my) {
            x = Math.max(4, Math.min(mx, root.width - width - 4))
            y = Math.max(4, Math.min(my, root.height - height - 4))
            visible = true
        }

        // ----------------------------------------------------
        // handleMenuAction — defined HERE (on contextMenu) so
        // the Repeater delegate can reach it via contextMenu.<fn>.
        // The delegate cannot see `root`, `input`, or `backend`
        // directly; this function runs in contextMenu's scope,
        // which CAN see all of them via the parent chain.
        // ----------------------------------------------------
        function handleMenuAction(act) {
            visible = false

            if (act === "reset") {
                root.moveToTopRight()
            } else if (act === "togglechat") {
                if (root.chatVisible) {
                    root.closeChat()
                } else {
                    root.chatVisible = true
                    if (root.backend) root.backend.setState("listening")
                    input.forceActiveFocus()
                }
            } else if (act === "flip") {
                if (root.backend) root.backend.playAnimation("flip")
            } else if (act === "dance") {
                if (root.backend) root.backend.playAnimation("dance")
            } else if (act === "spin") {
                if (root.backend) root.backend.playAnimation("spin360")
            } else if (act === "sleep") {
                if (root.backend) root.backend.setStateWithSound("sleepy")
            } else if (act === "celebrate") {
                if (root.backend) root.backend.setState("celebrating")
            } else if (act === "quit") {
                Qt.exit(0)
            }
        }

        Column {
            id: menuCol
            anchors.fill: parent
            anchors.margins: 4
            spacing: 1

            Repeater {
                model: [
                    { label: "Reset Position", act: "reset" },
                    { label: root.chatVisible ? "Close Chat" : "Open Chat", act: "togglechat" },
                    { label: "Do a Flip",      act: "flip"  },
                    { label: "Dance",          act: "dance" },
                    { label: "Spin 360",       act: "spin"  },
                    { label: "Sleep",          act: "sleep" },
                    { label: "Celebrate",      act: "celebrate" },
                    { label: "Quit",           act: "quit"  }
                ]

                Rectangle {
                    width: menuCol.width
                    height: 24
                    radius: 4
                    color: menuHover.containsMouse
                           ? "#44FFFFFF"
                           : "transparent"

                    Text {
                        anchors.left: parent.left
                        anchors.leftMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        text: modelData.label
                        color: "white"
                        font.pixelSize: 11
                    }

                    MouseArea {
                        id: menuHover
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: contextMenu.handleMenuAction(modelData.act)
                    }
                }
            }
        }
    }


    // ========================================================
    // CHAT PANEL (with tail)
    // ========================================================
    Item {
        id: chatAnchor
        anchors.top: view.bottom
        anchors.topMargin: -2
        anchors.horizontalCenter: parent.horizontalCenter
        width: parent.width - 30
        height: 96
        visible: root.chatVisible
        opacity: root.chatVisible ? 1 : 0
        scale:   root.chatVisible ? 1 : 0.95

        Behavior on opacity { NumberAnimation { duration: 160 } }
        Behavior on scale {
            NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
        }

        Rectangle {
            width: 14
            height: 14
            rotation: 45
            color: "#DD111111"
            x: parent.width / 2 - 7
            y: -7
            z: -1
        }

        Rectangle {
            id: chatPanel
            anchors.fill: parent
            anchors.topMargin: 6
            radius: 16
            color: "#DD111111"
            border.width: 1
            border.color: "#444444"

            Text {
                id: responseText
                x: 12
                y: 7
                width: parent.width - 24
                height: 36
                text: {
                    if (root.currentState === "thinking") {
                        var dots = ["", ".", "..", "..."]
                        return "Thinking" + dots[root.thinkDots]
                    }
                    if (root.currentState === "listening" &&
                        (!root.backend || root.backend.response.length === 0))
                        return "Listening…"
                    return root.backend ? root.backend.response : ""
                }
                color: "white"
                font.pixelSize: 12
                wrapMode: Text.WordWrap
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideRight
            }

            Rectangle {
                id: inputBackground
                x: 10
                y: 52
                width: parent.width - sendButton.width - 28
                height: 27
                radius: 11
                color: "#181818"
                border.width: 1
                border.color: input.activeFocus ? "#666666" : "#333333"

                TextInput {
                    id: input
                    anchors.fill: parent
                    anchors.leftMargin: 9
                    anchors.rightMargin: 8
                    color: "white"
                    font.pixelSize: 12
                    clip: true
                    selectByMouse: true
                    activeFocusOnPress: true

                    Keys.onReturnPressed: sendMessage()
                    Keys.onEnterPressed:  sendMessage()

                    Text {
                        anchors.fill: parent
                        visible: input.text.length === 0
                        text: "Talk to MAX..."
                        color: "#777777"
                        verticalAlignment: Text.AlignVCenter
                        font.pixelSize: 12
                    }
                }
            }

            Rectangle {
                id: sendButton
                width: 48
                height: 27
                x: parent.width - width - 10
                y: 52
                radius: 11
                color: sendMouse.containsMouse ? "#555555" : "#333333"

                Text {
                    anchors.centerIn: parent
                    text: "Send"
                    color: "white"
                    font.pixelSize: 11
                }

                MouseArea {
                    id: sendMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: sendMessage()
                }
            }
        }
    }


    // ========================================================
    // SEND MESSAGE
    // ========================================================
    function sendMessage() {
        var text = input.text.trim()
        if (text.length === 0) return
        if (root.backend) root.backend.chat(text)
        input.text = ""
        root.chatVisible = true
    }

    function closeChat() {
        root.chatVisible = false
        input.focus = false
        input.text = ""
        if (root.backend) root.backend.setState("idle")
    }


    // ========================================================
    // TIMERS
    // ========================================================
    Timer {
        id: appTimer
        interval: 1000
        repeat: true
        running: true
        onTriggered: if (root.backend) root.backend.refreshActiveApp()
    }

    Timer {
        id: speakTimer
        interval: 2800
        repeat: false
        onTriggered: if (root.backend) root.backend.setState("happy")
    }

    Timer {
        id: happyTimer
        interval: 1800
        repeat: false
        onTriggered: if (root.backend) root.backend.setState("idle")
    }
    Timer {
        id: pokePulseTimer
        interval: 180
        repeat: false
        onTriggered: root.pulse = 1.0
    }

    // ========================================================
    // START
    // ========================================================
    Component.onCompleted: {
        if (appSettings.firstRun) {
            moveToTopRight()
            appSettings.firstRun = false
        }
        updateState("idle")
        root.chatVisible = false
    }
}
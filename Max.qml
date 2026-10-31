import QtQuick
import QtQuick.Window
import QtQuick3D
import QtQuick3D.AssetUtils
import QtCore

Window {
    id: root

    // Normal mode has generous headroom (420x480) so high jumps never clip.
    // Standby mode uses the FULL screen so MAX has zero boundaries and can roam anywhere.
    readonly property int normalWidth: 420
    readonly property int normalHeight: 480

    width: standbyMode ? Screen.width : normalWidth
    height: standbyMode ? Screen.height : normalHeight

    visible: true
    color: "transparent"

    flags: Qt.FramelessWindowHint |
           Qt.WindowStaysOnTopHint |
           Qt.Tool


    // ========================================================
    // CONFIG & STANDBY (BOUNDARY-FREE ROAMING) MODE
    // ========================================================
    property string assetPath:
        Qt.resolvedUrl(
            "assets/Meshy_AI_Robo_Cat_Orb_0921143520_texture.glb"
        )
    property bool standbyMode: false
    property real modelScale: 28

    // Saved window coordinates before entering fullscreen Standby Mode
    property int savedX: 0
    property int savedY: 0

    // Roaming 3D offsets & smooth flight banking channels
    property real roamX: 0
    property real roamY: 0
    property real targetRoamX: 0
    property real targetRoamY: 0
    property real roamBankRoll: 0
    property real roamTurnYaw: 0
    property bool roamingInProgress: false

    // Z-axis close-up channel: positive values bring MAX smoothly toward the camera
    property real approachZ: 0

    property int standbyAnimIndex: 0
    property string currentShowcaseName: ""
    readonly property var standbyAnimations: [
        "inspect", "boop", "wave", "peekaboo", "levitate",
        "moonwalk", "flip", "dance", "celebrate", "spin360",
        "barrel", "jump", "bow", "dizzy", "heartbeat",
        "wiggle", "nod", "look", "stretch", "sneeze",
        "diagonal", "spin360x", "shiver", "attention"
    ]


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
    // DERIVED SCALE (gentle squash & stretch)
    // ========================================================
    readonly property real _jumpStretch: Math.max(0, jumpY) / 150

    readonly property real scaleX:
        pulse * (1 - _jumpStretch * 0.35) * (1 - blink * 0.05)
    readonly property real scaleY:
        pulse * (1 + _jumpStretch * 0.65) * (1 - blink * 0.15)
    readonly property real scaleZ:
        pulse * (1 - _jumpStretch * 0.35) * (1 - blink * 0.05)


    // ========================================================
    // STATE
    // ========================================================
    property string currentState: "idle"
    property bool advancedBusy: false
    property bool chatVisible: false
    property bool dragging: false

    property int thinkDots: 0

    readonly property var backend: (typeof maxBackend !== "undefined")
                                  ? maxBackend
                                  : null

    // When an animation finishes in Standby Mode, wait calmly before moving again
    onAdvancedBusyChanged: {
        if (!advancedBusy && standbyMode && !roamingInProgress && !dragging) {
            standbyRestTimer.restart()
        }
    }


    // ========================================================
    // SMOOTHED TRACKING BEHAVIORS
    // ========================================================
    Behavior on trackYaw   { SmoothedAnimation { velocity: 220 } }
    Behavior on trackPitch { SmoothedAnimation { velocity: 220 } }


    // ========================================================
    // WINDOW POSITION PERSISTENCE
    // ========================================================
    Settings {
        id: appSettings
        category: "MaxWindow"
        property int savedWindowX: -1
        property int savedWindowY: -1
        property bool firstRun: true
    }


    // ========================================================
    // 3D SCENE (BOUNDARY-FREE FULL VIEWPORT)
    // ========================================================
    View3D {
        id: view
        x: 0
        y: 0
        width: parent.width
        height: root.standbyMode ? parent.height : 360
        camera: camera

        environment: SceneEnvironment {
            clearColor: "transparent"
            backgroundMode: SceneEnvironment.Transparent
        }

        PerspectiveCamera {
            id: camera
            position: Qt.vector3d(0, 0, 290)
            fieldOfView: 35
            clipNear: 1.0
            clipFar: 2000.0
        }

        DirectionalLight {
            eulerRotation: Qt.vector3d(-35, -25, 0)
            brightness: 1.5
        }
        DirectionalLight {
            eulerRotation: Qt.vector3d(25, 150, 0)
            brightness: 0.85
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
                root.yaw   + root.spinYaw   + root.trackYaw + root.roamTurnYaw,
                root.roll  + root.spinRoll  + root.roamBankRoll
            )

            position: Qt.vector3d(
                -((bounds.maximum.x + bounds.minimum.x) / 2) * root.modelScale
                    + root.sideMove + root.roamX,
                -((bounds.maximum.y + bounds.minimum.y) / 2) * root.modelScale
                    + root.bob + root.jumpY + root.roamY - (root.standbyMode ? 0 : 12),
                -((bounds.maximum.z + bounds.minimum.z) / 2) * root.modelScale
                    + root.approachZ
            )
        }
    }


    // ========================================================
    // 2D SCREEN PROJECTION HELPERS (FOLLOWS MAX AS HE ROAMS)
    // ========================================================
    readonly property real roboScreenX:
        view.width / 2 + (root.roamX + root.sideMove) * (view.height / 185)
    readonly property real roboScreenY:
        view.height / 2 - (root.roamY - (root.standbyMode ? 0 : 12)) * (view.height / 185)
    readonly property real zoomFactor:
        Math.max(0.7, 290 / Math.max(80, 290 - root.approachZ))


    // ========================================================
    // STANDBY FLOATING BADGE (SMOOTHLY FOLLOWS MAX)
    // ========================================================
    Rectangle {
        id: standbyBadge
        visible: root.standbyMode
        z: 10
        x: Math.max(12, Math.min(root.width - width - 12, root.roboScreenX - width / 2))
        y: Math.max(12, root.roboScreenY - 135 * root.zoomFactor)
        width: badgeRow.implicitWidth + 28
        height: 28
        radius: 14
        color: "#CC111111"
        border.color: "#55AAFF"
        border.width: 1

        Row {
            id: badgeRow
            anchors.centerIn: parent
            spacing: 10

            Text {
                text: "STANDBY ROAM  •  " + (root.roamingInProgress ? "GLIDING..." : (root.currentShowcaseName ? root.currentShowcaseName.toUpperCase() : "RELAXING"))
                color: "#AADDFF"
                font.pixelSize: 11
                font.bold: true
                anchors.verticalCenter: parent.verticalCenter
            }

            Rectangle {
                width: 46
                height: 18
                radius: 9
                color: exitHover.containsMouse ? "#FF5555" : "#33FFFFFF"
                anchors.verticalCenter: parent.verticalCenter

                Text {
                    anchors.centerIn: parent
                    text: "EXIT"
                    color: "white"
                    font.pixelSize: 9
                    font.bold: true
                }

                MouseArea {
                    id: exitHover
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: root.toggleStandbyMode(false)
                }
            }
        }
    }


    // ========================================================
    // SHADOW BLOB (FOLLOWS MAX ACROSS THE SCREEN)
    // ========================================================
    Item {
        id: shadowLayer
        z: 1
        anchors.fill: view
        enabled: false

        Rectangle {
            width: 96 * root.zoomFactor
            height: 18 * root.zoomFactor
            radius: height / 2
            color: "#66000000"
            x: root.roboScreenX - width / 2
            y: root.roboScreenY + (95 * root.zoomFactor) + root.bob * 0.4
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
                var speed = (55 + Math.random() * 130) * root.zoomFactor
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
            burst(count, color, root.roboScreenX, root.roboScreenY)
        }
    }

    Component {
        id: sparkleComponent

        Rectangle {
            id: sparkleItem
            property color sparkColor: "#FFDD88"
            property real  targetX: 0
            property real  targetY: 0

            width: 5 + Math.random() * 5
            height: width
            radius: width / 2
            color: sparkColor
            opacity: 0

            ParallelAnimation {
                running: true
                NumberAnimation {
                    target: sparkleItem; property: "x"
                    to: sparkleItem.targetX
                    duration: 1100; easing.type: Easing.OutCubic
                }
                NumberAnimation {
                    target: sparkleItem; property: "y"
                    to: sparkleItem.targetY
                    duration: 1100; easing.type: Easing.OutCubic
                }
                NumberAnimation {
                    target: sparkleItem; property: "opacity"
                    from: 1; to: 0
                    duration: 1100
                }
                NumberAnimation {
                    target: sparkleItem; property: "scale"
                    from: 1.4; to: 0.2
                    duration: 1100
                }
            }

            Timer {
                interval: 1150
                running: true
                onTriggered: sparkleItem.destroy()
            }
        }
    }


    // ========================================================
    // SMOOTH ROAMING FLIGHT ANIMATION (BANK -> GLIDE -> SETTLE)
    // ========================================================
    ParallelAnimation {
        id: roamTravelAnim
        onStarted: root.roamingInProgress = true
        onStopped: {
            root.roamingInProgress = false
            root.roamBankRoll = 0
            root.roamTurnYaw = 0
            if (root.standbyMode && !root.dragging) {
                standbyArrivalTimer.restart()
            }
        }

        NumberAnimation {
            target: root; property: "roamX"
            to: root.targetRoamX
            duration: 2800
            easing.type: Easing.InOutSine
        }
        NumberAnimation {
            target: root; property: "roamY"
            to: root.targetRoamY
            duration: 2800
            easing.type: Easing.InOutSine
        }
        SequentialAnimation {
            ParallelAnimation {
                NumberAnimation {
                    target: root; property: "roamBankRoll"
                    to: (root.targetRoamX >= root.roamX) ? -14 : 14
                    duration: 900; easing.type: Easing.OutSine
                }
                NumberAnimation {
                    target: root; property: "roamTurnYaw"
                    to: (root.targetRoamX >= root.roamX) ? 18 : -18
                    duration: 900; easing.type: Easing.OutSine
                }
            }
            PauseAnimation { duration: 1000 }
            ParallelAnimation {
                NumberAnimation {
                    target: root; property: "roamBankRoll"
                    to: 0; duration: 900; easing.type: Easing.InOutSine
                }
                NumberAnimation {
                    target: root; property: "roamTurnYaw"
                    to: 0; duration: 900; easing.type: Easing.InOutSine
                }
            }
        }
    }


    // ========================================================
    // IDLE ANIMATIONS (ULTRA-SMOOTH BREATHING & FLOATING)
    // ========================================================
    SequentialAnimation {
        id: idleFloat
        loops: Animation.Infinite
        NumberAnimation {
            target: root; property: "bob"
            from: -4; to: 4
            duration: 2800; easing.type: Easing.InOutSine
        }
        NumberAnimation {
            target: root; property: "bob"
            from: 4; to: -4
            duration: 2800; easing.type: Easing.InOutSine
        }
    }

    SequentialAnimation {
        id: idleYaw
        loops: Animation.Infinite
        NumberAnimation {
            target: root; property: "yaw"
            from: -7; to: 7
            duration: 4200; easing.type: Easing.InOutSine
        }
        NumberAnimation {
            target: root; property: "yaw"
            from: 7; to: -7
            duration: 4200; easing.type: Easing.InOutSine
        }
    }

    SequentialAnimation {
        id: idleTilt
        loops: Animation.Infinite
        PauseAnimation { duration: 2600 }
        NumberAnimation {
            target: root; property: "roll"
            from: -3; to: 3
            duration: 1600; easing.type: Easing.InOutSine
        }
        NumberAnimation {
            target: root; property: "roll"
            from: 3; to: -3
            duration: 1600; easing.type: Easing.InOutSine
        }
        PauseAnimation { duration: 2600 }
    }

    // Blink cycle
    SequentialAnimation {
        id: blinkAnim
        NumberAnimation {
            target: root; property: "blink"
            to: 1; duration: 90; easing.type: Easing.InOutQuad
        }
        NumberAnimation {
            target: root; property: "blink"
            to: 0; duration: 150; easing.type: Easing.InOutQuad
        }
    }

    Timer {
        id: blinkTimer
        interval: 3000 + Math.random() * 4000
        running: root.currentState === "idle" || root.standbyMode
        repeat: true
        onTriggered: {
            blinkAnim.restart()
            interval = 3000 + Math.random() * 4000
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
            duration: 1100; easing.type: Easing.InOutSine
        }
        NumberAnimation {
            target: root; property: "yaw"
            from: 15; to: -15
            duration: 1100; easing.type: Easing.InOutSine
        }
    }

    SequentialAnimation {
        id: thinkingBob
        loops: Animation.Infinite
        NumberAnimation {
            target: root; property: "bob"
            from: -6; to: 6
            duration: 850; easing.type: Easing.InOutSine
        }
        NumberAnimation {
            target: root; property: "bob"
            from: 6; to: -6
            duration: 850; easing.type: Easing.InOutSine
        }
    }

    SequentialAnimation {
        id: thinkingTilt
        loops: Animation.Infinite
        NumberAnimation {
            target: root; property: "roll"
            from: -6; to: 6
            duration: 1600; easing.type: Easing.InOutSine
        }
        NumberAnimation {
            target: root; property: "roll"
            from: 6; to: -6
            duration: 1600; easing.type: Easing.InOutSine
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
            duration: 420; easing.type: Easing.InOutSine
        }
        NumberAnimation {
            target: root; property: "pulse"
            from: 1.045; to: 1.0
            duration: 420; easing.type: Easing.InOutSine
        }
    }

    SequentialAnimation {
        id: speakingMovement
        loops: Animation.Infinite
        NumberAnimation {
            target: root; property: "bob"
            from: -3; to: 4
            duration: 500; easing.type: Easing.InOutSine
        }
        NumberAnimation {
            target: root; property: "bob"
            from: 4; to: -3
            duration: 500; easing.type: Easing.InOutSine
        }
    }

    SequentialAnimation {
        id: speakingRoll
        loops: Animation.Infinite
        NumberAnimation {
            target: root; property: "roll"
            from: -4; to: 4
            duration: 750; easing.type: Easing.InOutSine
        }
        NumberAnimation {
            target: root; property: "roll"
            from: 4; to: -4
            duration: 750; easing.type: Easing.InOutSine
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
                from: 0; to: 20
                duration: 380; easing.type: Easing.OutSine
            }
            NumberAnimation {
                target: root; property: "spinYaw"
                from: 0; to: 360
                duration: 820; easing.type: Easing.InOutSine
            }
            NumberAnimation {
                target: root; property: "pulse"
                from: 1; to: 1.07
                duration: 380; easing.type: Easing.OutSine
            }
        }
        ParallelAnimation {
            NumberAnimation {
                target: root; property: "jumpY"
                from: 20; to: 0
                duration: 480; easing.type: Easing.InOutSine
            }
            NumberAnimation {
                target: root; property: "pulse"
                from: 1.07; to: 1
                duration: 480; easing.type: Easing.InOutSine
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
            duration: 140; easing.type: Easing.InOutSine
        }
        NumberAnimation {
            target: root; property: "yaw"
            from: 10; to: -10
            duration: 140; easing.type: Easing.InOutSine
        }
        NumberAnimation {
            target: root; property: "pitch"
            from: -4; to: 4
            duration: 140; easing.type: Easing.InOutSine
        }
        NumberAnimation {
            target: root; property: "pitch"
            from: 4; to: -4
            duration: 140; easing.type: Easing.InOutSine
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
            duration: 1100; easing.type: Easing.InOutSine
        }
        NumberAnimation {
            target: root; property: "roll"
            from: 6; to: -6
            duration: 1100; easing.type: Easing.InOutSine
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
            duration: 3400; easing.type: Easing.InOutSine
        }
        NumberAnimation {
            target: root; property: "bob"
            from: 3; to: -2
            duration: 3400; easing.type: Easing.InOutSine
        }
    }

    SequentialAnimation {
        id: sleepyDroop
        loops: Animation.Infinite
        NumberAnimation {
            target: root; property: "pitch"
            from: 0; to: 12
            duration: 2800; easing.type: Easing.InOutSine
        }
        NumberAnimation {
            target: root; property: "pitch"
            from: 12; to: 0
            duration: 2800; easing.type: Easing.InOutSine
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
            duration: 320; easing.type: Easing.InOutSine
        }
        NumberAnimation {
            target: root; property: "bob"
            from: 8; to: -5
            duration: 320; easing.type: Easing.InOutSine
        }
    }

    SequentialAnimation {
        id: excitedSpin
        loops: Animation.Infinite
        NumberAnimation {
            target: root; property: "spinYaw"
            from: 0; to: 360
            duration: 1300; easing.type: Easing.InOutSine
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
            to: 25; duration: 900; easing.type: Easing.InOutSine
        }
        PauseAnimation { duration: 800 }
        NumberAnimation {
            target: root; property: "spinYaw"
            to: -25; duration: 1200; easing.type: Easing.InOutSine
        }
        PauseAnimation { duration: 800 }
        NumberAnimation {
            target: root; property: "spinYaw"
            to: 0; duration: 850; easing.type: Easing.InOutSine
        }
    }


    // ========================================================
    // CELEBRATING
    // ========================================================
    SequentialAnimation {
        id: celebratingAnim
        loops: 2
        onStarted: {
            root.advancedBusy = true
            sparkleLayer.burstAtModel(28, "#FFD700")
        }
        onStopped: {
            root.spinRoll = 0
            root.jumpY = 0
            root.advancedBusy = false
        }

        ParallelAnimation {
            NumberAnimation {
                target: root; property: "spinRoll"
                from: 0; to: 360
                duration: 1250; easing.type: Easing.InOutSine
            }
            SequentialAnimation {
                NumberAnimation {
                    target: root; property: "jumpY"
                    from: 0; to: 18
                    duration: 550; easing.type: Easing.OutSine
                }
                NumberAnimation {
                    target: root; property: "jumpY"
                    from: 18; to: 0
                    duration: 700; easing.type: Easing.InOutSine
                }
            }
        }
    }


    // ========================================================
    // SMOOTH ACTION, CLOSE-UP & SHOWCASE ANIMATIONS
    // ========================================================

    // ---- CLOSE-UP 1: INSPECT (glides smoothly toward camera and looks around) ----
    SequentialAnimation {
        id: rndInspect
        onStarted: root.advancedBusy = true
        onStopped: {
            root.approachZ = 0
            root.spinYaw = 0
            root.spinPitch = 0
            root.spinRoll = 0
            root.advancedBusy = false
        }

        NumberAnimation {
            target: root; property: "approachZ"
            to: 105; duration: 1100; easing.type: Easing.InOutSine
        }
        ParallelAnimation {
            NumberAnimation { target: root; property: "spinYaw"; to: 22; duration: 750; easing.type: Easing.InOutSine }
            NumberAnimation { target: root; property: "spinRoll"; to: 10; duration: 750; easing.type: Easing.InOutSine }
        }
        PauseAnimation { duration: 450 }
        ParallelAnimation {
            NumberAnimation { target: root; property: "spinYaw"; to: -22; duration: 900; easing.type: Easing.InOutSine }
            NumberAnimation { target: root; property: "spinRoll"; to: -10; duration: 900; easing.type: Easing.InOutSine }
            NumberAnimation { target: root; property: "spinPitch"; to: 8; duration: 900; easing.type: Easing.InOutSine }
        }
        PauseAnimation { duration: 450 }
        ParallelAnimation {
            NumberAnimation { target: root; property: "spinYaw"; to: 0; duration: 800; easing.type: Easing.InOutSine }
            NumberAnimation { target: root; property: "spinRoll"; to: 0; duration: 800; easing.type: Easing.InOutSine }
            NumberAnimation { target: root; property: "spinPitch"; to: 0; duration: 800; easing.type: Easing.InOutSine }
            NumberAnimation { target: root; property: "approachZ"; to: 0; duration: 1000; easing.type: Easing.InOutSine }
        }
    }

    // ---- CLOSE-UP 2: BOOP (approaches smoothly and gently boops the screen) ----
    SequentialAnimation {
        id: rndBoop
        onStarted: root.advancedBusy = true
        onStopped: {
            root.approachZ = 0
            root.spinPitch = 0
            root.pulse = 1.0
            root.advancedBusy = false
        }

        NumberAnimation {
            target: root; property: "approachZ"
            to: 90; duration: 900; easing.type: Easing.InOutSine
        }
        PauseAnimation { duration: 350 }
        ScriptAction { script: sparkleLayer.burstAtModel(18, "#FF99CC") }
        ParallelAnimation {
            NumberAnimation { target: root; property: "approachZ"; to: 118; duration: 280; easing.type: Easing.OutSine }
            NumberAnimation { target: root; property: "spinPitch"; to: 14; duration: 280; easing.type: Easing.OutSine }
            NumberAnimation { target: root; property: "pulse"; to: 1.1; duration: 280; easing.type: Easing.OutSine }
        }
        ParallelAnimation {
            NumberAnimation { target: root; property: "approachZ"; to: 85; duration: 450; easing.type: Easing.InOutSine }
            NumberAnimation { target: root; property: "spinPitch"; to: -6; duration: 450; easing.type: Easing.InOutSine }
            NumberAnimation { target: root; property: "pulse"; to: 1.0; duration: 450; easing.type: Easing.InOutSine }
        }
        PauseAnimation { duration: 400 }
        ParallelAnimation {
            NumberAnimation { target: root; property: "approachZ"; to: 0; duration: 950; easing.type: Easing.InOutSine }
            NumberAnimation { target: root; property: "spinPitch"; to: 0; duration: 950; easing.type: Easing.InOutSine }
        }
    }

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
            duration: 1400; easing.type: Easing.InOutSine
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
            duration: 1400; easing.type: Easing.InOutSine
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
            duration: 1350; easing.type: Easing.InOutSine
        }
    }

    SequentialAnimation {
        id: rndDiagonalTilt
        onStarted: root.advancedBusy = true
        onStopped: root.advancedBusy = false

        ParallelAnimation {
            NumberAnimation {
                target: root; property: "spinPitch"
                to: 38; duration: 750; easing.type: Easing.InOutSine
            }
            NumberAnimation {
                target: root; property: "spinYaw"
                to: 38; duration: 750; easing.type: Easing.InOutSine
            }
            NumberAnimation {
                target: root; property: "jumpY"
                to: 10; duration: 750; easing.type: Easing.InOutSine
            }
        }
        PauseAnimation { duration: 750 }
        ParallelAnimation {
            NumberAnimation {
                target: root; property: "spinPitch"
                to: 0; duration: 800; easing.type: Easing.InOutSine
            }
            NumberAnimation {
                target: root; property: "spinYaw"
                to: 0; duration: 800; easing.type: Easing.InOutSine
            }
            NumberAnimation {
                target: root; property: "jumpY"
                to: 0; duration: 800; easing.type: Easing.InOutSine
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
            to: 18; duration: 320; easing.type: Easing.InOutSine
        }
        NumberAnimation {
            target: root; property: "spinPitch"
            to: -6; duration: 320; easing.type: Easing.InOutSine
        }
        NumberAnimation {
            target: root; property: "spinPitch"
            to: 0; duration: 280; easing.type: Easing.InOutSine
        }
    }

    SequentialAnimation {
        id: rndLookAround
        onStarted: root.advancedBusy = true
        onStopped: root.advancedBusy = false

        NumberAnimation {
            target: root; property: "spinYaw"
            to: 35; duration: 850; easing.type: Easing.InOutSine
        }
        PauseAnimation { duration: 650 }
        NumberAnimation {
            target: root; property: "spinYaw"
            to: -35; duration: 1200; easing.type: Easing.InOutSine
        }
        PauseAnimation { duration: 650 }
        NumberAnimation {
            target: root; property: "spinYaw"
            to: 0; duration: 850; easing.type: Easing.InOutSine
        }
    }

    SequentialAnimation {
        id: rndBounce
        onStarted: root.advancedBusy = true
        onStopped: root.advancedBusy = false

        NumberAnimation {
            target: root; property: "jumpY"
            to: -6; duration: 280; easing.type: Easing.InOutSine
        }
        NumberAnimation {
            target: root; property: "jumpY"
            to: 24; duration: 450; easing.type: Easing.OutSine
        }
        NumberAnimation {
            target: root; property: "jumpY"
            to: 0; duration: 750; easing.type: Easing.OutBounce
        }
    }

    SequentialAnimation {
        id: rndWiggle
        loops: 3
        onStarted: root.advancedBusy = true
        onStopped: {
            root.spinRoll = 0
            root.spinYaw = 0
            root.advancedBusy = false
        }

        ParallelAnimation {
            NumberAnimation {
                target: root; property: "spinRoll"
                to: 12; duration: 180; easing.type: Easing.InOutSine
            }
            NumberAnimation {
                target: root; property: "spinYaw"
                to: 8; duration: 180; easing.type: Easing.InOutSine
            }
        }
        ParallelAnimation {
            NumberAnimation {
                target: root; property: "spinRoll"
                to: -12; duration: 180; easing.type: Easing.InOutSine
            }
            NumberAnimation {
                target: root; property: "spinYaw"
                to: -8; duration: 180; easing.type: Easing.InOutSine
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
                to: -10; duration: 550; easing.type: Easing.InOutSine
            }
            NumberAnimation {
                target: root; property: "jumpY"
                to: -5; duration: 550; easing.type: Easing.InOutSine
            }
        }
        ParallelAnimation {
            NumberAnimation {
                target: root; property: "spinPitch"
                to: 24; duration: 180; easing.type: Easing.OutSine
            }
            NumberAnimation {
                target: root; property: "jumpY"
                to: 12; duration: 180; easing.type: Easing.OutSine
            }
            NumberAnimation {
                target: root; property: "pulse"
                to: 1.12; duration: 180
            }
        }
        ParallelAnimation {
            NumberAnimation {
                target: root; property: "spinPitch"
                to: 0; duration: 750; easing.type: Easing.InOutSine
            }
            NumberAnimation {
                target: root; property: "jumpY"
                to: 0; duration: 750; easing.type: Easing.InOutSine
            }
            NumberAnimation {
                target: root; property: "pulse"
                to: 1; duration: 750; easing.type: Easing.InOutSine
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
                to: -12; duration: 850; easing.type: Easing.InOutSine
            }
            NumberAnimation {
                target: root; property: "jumpY"
                to: 8; duration: 850; easing.type: Easing.InOutSine
            }
            NumberAnimation {
                target: root; property: "pulse"
                to: 1.08; duration: 850; easing.type: Easing.InOutSine
            }
        }
        PauseAnimation { duration: 550 }
        ParallelAnimation {
            NumberAnimation {
                target: root; property: "spinPitch"
                to: 0; duration: 950; easing.type: Easing.InOutSine
            }
            NumberAnimation {
                target: root; property: "jumpY"
                to: 0; duration: 950; easing.type: Easing.InOutSine
            }
            NumberAnimation {
                target: root; property: "pulse"
                to: 1; duration: 950; easing.type: Easing.InOutSine
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
                to: -22; duration: 650; easing.type: Easing.InOutSine
            }
            NumberAnimation {
                target: root; property: "spinPitch"
                to: -6; duration: 650; easing.type: Easing.InOutSine
            }
        }
        PauseAnimation { duration: 1000 }
        ParallelAnimation {
            NumberAnimation {
                target: root; property: "spinYaw"
                to: 0; duration: 750; easing.type: Easing.InOutSine
            }
            NumberAnimation {
                target: root; property: "spinPitch"
                to: 0; duration: 750; easing.type: Easing.InOutSine
            }
        }
    }

    // ---- FLIP (smooth 360 somersault on X while airborne) ----
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
                duration: 1200; easing.type: Easing.InOutSine
            }
            SequentialAnimation {
                NumberAnimation {
                    target: root; property: "jumpY"
                    to: 24; duration: 600; easing.type: Easing.OutSine
                }
                NumberAnimation {
                    target: root; property: "jumpY"
                    to: 0; duration: 600; easing.type: Easing.InOutSine
                }
            }
        }
    }

    // ---- DANCE (graceful rhythmic sway + hop) ----
    SequentialAnimation {
        id: rndDance
        onStarted: root.advancedBusy = true
        onStopped: {
            root.spinYaw = 0
            root.spinRoll = 0
            root.bob = 0
            root.advancedBusy = false
        }

        SequentialAnimation {
            loops: 3
            ParallelAnimation {
                NumberAnimation {
                    target: root; property: "spinYaw"
                    to: 28; duration: 380; easing.type: Easing.InOutSine
                }
                NumberAnimation {
                    target: root; property: "spinRoll"
                    to: 16; duration: 380; easing.type: Easing.InOutSine
                }
                NumberAnimation {
                    target: root; property: "bob"
                    to: 10; duration: 380; easing.type: Easing.InOutSine
                }
            }
            ParallelAnimation {
                NumberAnimation {
                    target: root; property: "spinYaw"
                    to: -28; duration: 380; easing.type: Easing.InOutSine
                }
                NumberAnimation {
                    target: root; property: "spinRoll"
                    to: -16; duration: 380; easing.type: Easing.InOutSine
                }
                NumberAnimation {
                    target: root; property: "bob"
                    to: 0; duration: 380; easing.type: Easing.InOutSine
                }
            }
        }
        ParallelAnimation {
            NumberAnimation { target: root; property: "spinYaw"; to: 0; duration: 350; easing.type: Easing.InOutSine }
            NumberAnimation { target: root; property: "spinRoll"; to: 0; duration: 350; easing.type: Easing.InOutSine }
            NumberAnimation { target: root; property: "bob"; to: 0; duration: 350; easing.type: Easing.InOutSine }
        }
    }

    // ---- WAVE (glides close and waves hello smoothly) ----
    SequentialAnimation {
        id: rndWave
        onStarted: {
            root.advancedBusy = true
            sparkleLayer.burstAtModel(12, "#88FFAA")
        }
        onStopped: {
            root.spinRoll = 0
            root.sideMove = 0
            root.jumpY = 0
            root.approachZ = 0
            root.advancedBusy = false
        }

        NumberAnimation { target: root; property: "approachZ"; to: 75; duration: 750; easing.type: Easing.InOutSine }
        SequentialAnimation {
            loops: 2
            ParallelAnimation {
                NumberAnimation { target: root; property: "spinRoll"; to: 22; duration: 340; easing.type: Easing.InOutSine }
                NumberAnimation { target: root; property: "sideMove"; to: 14; duration: 340; easing.type: Easing.InOutSine }
                NumberAnimation { target: root; property: "jumpY"; to: 10; duration: 340; easing.type: Easing.InOutSine }
            }
            ParallelAnimation {
                NumberAnimation { target: root; property: "spinRoll"; to: -22; duration: 380; easing.type: Easing.InOutSine }
                NumberAnimation { target: root; property: "sideMove"; to: -14; duration: 380; easing.type: Easing.InOutSine }
            }
        }
        ParallelAnimation {
            NumberAnimation { target: root; property: "spinRoll"; to: 0; duration: 500; easing.type: Easing.InOutSine }
            NumberAnimation { target: root; property: "sideMove"; to: 0; duration: 500; easing.type: Easing.InOutSine }
            NumberAnimation { target: root; property: "jumpY"; to: 0; duration: 500; easing.type: Easing.InOutSine }
            NumberAnimation { target: root; property: "approachZ"; to: 0; duration: 750; easing.type: Easing.InOutSine }
        }
    }

    // ---- BOW (deep respectful forward bow) ----
    SequentialAnimation {
        id: rndBow
        onStarted: root.advancedBusy = true
        onStopped: {
            root.spinPitch = 0
            root.jumpY = 0
            root.advancedBusy = false
        }

        ParallelAnimation {
            NumberAnimation { target: root; property: "spinPitch"; to: 40; duration: 850; easing.type: Easing.InOutSine }
            NumberAnimation { target: root; property: "jumpY"; to: -6; duration: 850; easing.type: Easing.InOutSine }
        }
        PauseAnimation { duration: 800 }
        ParallelAnimation {
            NumberAnimation { target: root; property: "spinPitch"; to: 0; duration: 850; easing.type: Easing.InOutSine }
            NumberAnimation { target: root; property: "jumpY"; to: 0; duration: 850; easing.type: Easing.InOutSine }
        }
    }

    // ---- PEEKABOO (ducks back softly, then pops close to camera) ----
    SequentialAnimation {
        id: rndPeekaboo
        onStarted: root.advancedBusy = true
        onStopped: {
            root.jumpY = 0
            root.pulse = 1.0
            root.spinYaw = 0
            root.approachZ = 0
            root.advancedBusy = false
        }

        ParallelAnimation {
            NumberAnimation { target: root; property: "jumpY"; to: -24; duration: 650; easing.type: Easing.InOutSine }
            NumberAnimation { target: root; property: "pulse"; to: 0.55; duration: 650; easing.type: Easing.InOutSine }
            NumberAnimation { target: root; property: "approachZ"; to: -35; duration: 650; easing.type: Easing.InOutSine }
        }
        PauseAnimation { duration: 700 }
        ScriptAction { script: sparkleLayer.burstAtModel(24, "#FF88DD") }
        ParallelAnimation {
            NumberAnimation { target: root; property: "jumpY"; to: 14; duration: 500; easing.type: Easing.OutBack }
            NumberAnimation { target: root; property: "pulse"; to: 1.08; duration: 500; easing.type: Easing.OutSine }
            NumberAnimation { target: root; property: "approachZ"; to: 100; duration: 550; easing.type: Easing.OutBack }
            NumberAnimation { target: root; property: "spinYaw"; from: 0; to: 360; duration: 850; easing.type: Easing.InOutSine }
        }
        PauseAnimation { duration: 550 }
        ParallelAnimation {
            NumberAnimation { target: root; property: "jumpY"; to: 0; duration: 750; easing.type: Easing.InOutSine }
            NumberAnimation { target: root; property: "pulse"; to: 1.0; duration: 750; easing.type: Easing.InOutSine }
            NumberAnimation { target: root; property: "approachZ"; to: 0; duration: 850; easing.type: Easing.InOutSine }
        }
    }

    // ---- DIZZY (smooth multi-spin followed by gentle wobble) ----
    SequentialAnimation {
        id: rndDizzy
        onStarted: root.advancedBusy = true
        onStopped: {
            root.spinYaw = 0
            root.spinRoll = 0
            root.spinPitch = 0
            root.advancedBusy = false
        }

        ParallelAnimation {
            NumberAnimation { target: root; property: "spinYaw"; from: 0; to: 720; duration: 1600; easing.type: Easing.InOutSine }
            NumberAnimation { target: root; property: "spinRoll"; to: 18; duration: 800; easing.type: Easing.InOutSine }
        }
        NumberAnimation { target: root; property: "spinRoll"; to: -18; duration: 450; easing.type: Easing.InOutSine }
        NumberAnimation { target: root; property: "spinRoll"; to: 12; duration: 450; easing.type: Easing.InOutSine }
        NumberAnimation { target: root; property: "spinRoll"; to: 0; duration: 500; easing.type: Easing.InOutSine }
    }

    // ---- SHIVER (gentle cold tremble) ----
    SequentialAnimation {
        id: rndShiver
        onStarted: root.advancedBusy = true
        onStopped: {
            root.sideMove = 0
            root.spinRoll = 0
            root.advancedBusy = false
        }

        SequentialAnimation {
            loops: 5
            ParallelAnimation {
                NumberAnimation { target: root; property: "sideMove"; to: 4; duration: 85; easing.type: Easing.InOutSine }
                NumberAnimation { target: root; property: "spinRoll"; to: 5; duration: 85; easing.type: Easing.InOutSine }
            }
            ParallelAnimation {
                NumberAnimation { target: root; property: "sideMove"; to: -4; duration: 85; easing.type: Easing.InOutSine }
                NumberAnimation { target: root; property: "spinRoll"; to: -5; duration: 85; easing.type: Easing.InOutSine }
            }
        }
        ParallelAnimation {
            NumberAnimation { target: root; property: "sideMove"; to: 0; duration: 200; easing.type: Easing.InOutSine }
            NumberAnimation { target: root; property: "spinRoll"; to: 0; duration: 200; easing.type: Easing.InOutSine }
        }
    }

    // ---- HEARTBEAT (close-up double-thump scale pulse) ----
    SequentialAnimation {
        id: rndHeartbeat
        onStarted: {
            root.advancedBusy = true
            sparkleLayer.burstAtModel(14, "#FF5577")
        }
        onStopped: {
            root.pulse = 1.0
            root.approachZ = 0
            root.advancedBusy = false
        }

        NumberAnimation { target: root; property: "approachZ"; to: 70; duration: 700; easing.type: Easing.InOutSine }
        SequentialAnimation {
            loops: 2
            NumberAnimation { target: root; property: "pulse"; to: 1.14; duration: 180; easing.type: Easing.OutSine }
            NumberAnimation { target: root; property: "pulse"; to: 1.02; duration: 180; easing.type: Easing.InOutSine }
            NumberAnimation { target: root; property: "pulse"; to: 1.20; duration: 220; easing.type: Easing.OutSine }
            NumberAnimation { target: root; property: "pulse"; to: 1.0;  duration: 450; easing.type: Easing.InOutSine }
            PauseAnimation { duration: 300 }
        }
        NumberAnimation { target: root; property: "approachZ"; to: 0; duration: 750; easing.type: Easing.InOutSine }
    }

    // ---- LEVITATE (ascend smoothly, hover with slow rotation, descend) ----
    SequentialAnimation {
        id: rndLevitate
        onStarted: {
            root.advancedBusy = true
            sparkleLayer.burstAtModel(25, "#77EEFF")
        }
        onStopped: {
            root.jumpY = 0
            root.spinYaw = 0
            root.spinRoll = 0
            root.approachZ = 0
            root.advancedBusy = false
        }

        ParallelAnimation {
            NumberAnimation { target: root; property: "jumpY"; to: 20; duration: 1000; easing.type: Easing.InOutSine }
            NumberAnimation { target: root; property: "approachZ"; to: 65; duration: 1000; easing.type: Easing.InOutSine }
        }
        ParallelAnimation {
            NumberAnimation { target: root; property: "spinYaw"; from: 0; to: 360; duration: 2200; easing.type: Easing.InOutSine }
            SequentialAnimation {
                NumberAnimation { target: root; property: "jumpY"; to: 26; duration: 1100; easing.type: Easing.InOutSine }
                NumberAnimation { target: root; property: "jumpY"; to: 18; duration: 1100; easing.type: Easing.InOutSine }
            }
        }
        ParallelAnimation {
            NumberAnimation { target: root; property: "jumpY"; to: 0; duration: 950; easing.type: Easing.InOutSine }
            NumberAnimation { target: root; property: "approachZ"; to: 0; duration: 950; easing.type: Easing.InOutSine }
        }
    }

    // ---- MOONWALK (wide smooth lateral glide) ----
    SequentialAnimation {
        id: rndMoonwalk
        onStarted: root.advancedBusy = true
        onStopped: {
            root.sideMove = 0
            root.spinYaw = 0
            root.spinPitch = 0
            root.advancedBusy = false
        }

        NumberAnimation { target: root; property: "spinYaw"; to: -35; duration: 450; easing.type: Easing.InOutSine }
        ParallelAnimation {
            NumberAnimation { target: root; property: "sideMove"; to: -36; duration: 1200; easing.type: Easing.InOutSine }
            SequentialAnimation {
                NumberAnimation { target: root; property: "spinPitch"; to: 8; duration: 400; easing.type: Easing.InOutSine }
                NumberAnimation { target: root; property: "spinPitch"; to: -8; duration: 400; easing.type: Easing.InOutSine }
                NumberAnimation { target: root; property: "spinPitch"; to: 0; duration: 400; easing.type: Easing.InOutSine }
            }
        }
        NumberAnimation { target: root; property: "spinYaw"; to: 35; duration: 450; easing.type: Easing.InOutSine }
        ParallelAnimation {
            NumberAnimation { target: root; property: "sideMove"; to: 36; duration: 1400; easing.type: Easing.InOutSine }
            SequentialAnimation {
                NumberAnimation { target: root; property: "spinPitch"; to: 8; duration: 460; easing.type: Easing.InOutSine }
                NumberAnimation { target: root; property: "spinPitch"; to: -8; duration: 460; easing.type: Easing.InOutSine }
                NumberAnimation { target: root; property: "spinPitch"; to: 0; duration: 480; easing.type: Easing.InOutSine }
            }
        }
        ParallelAnimation {
            NumberAnimation { target: root; property: "sideMove"; to: 0; duration: 850; easing.type: Easing.InOutSine }
            NumberAnimation { target: root; property: "spinYaw"; to: 0; duration: 850; easing.type: Easing.InOutSine }
        }
    }


    // ========================================================
    // RANDOM IDLE SCHEDULER & PACED STANDBY ROAMING CHOREOGRAPHY
    // ========================================================
    Timer {
        id: randomIdleTimer
        repeat: true
        running: root.currentState === "idle" && !root.standbyMode
        interval: 8500

        onTriggered: {
            if (!root.advancedBusy && !root.dragging)
                root.playRandomIdle()
            randomIdleTimer.interval = 7500 + Math.random() * 6500
        }
    }

    // Step 1 -> Step 2 Pause: After gliding to a new spot, settle for 1.2s before animating
    Timer {
        id: standbyArrivalTimer
        repeat: false
        interval: 1200
        onTriggered: {
            if (!root.standbyMode || root.dragging) return
            var animName = root.standbyAnimations[root.standbyAnimIndex]
            root.currentShowcaseName = animName
            if (root.backend) root.backend.playAnimation(animName)
            else root.playNamedAnimation(animName)
            root.standbyAnimIndex = (root.standbyAnimIndex + 1) % root.standbyAnimations.length
        }
    }

    // Step 3 Rest Pause: After an animation completes, float calmly for 4.5s before gliding to next spot
    Timer {
        id: standbyRestTimer
        repeat: false
        interval: 4500
        onTriggered: {
            if (root.standbyMode && !root.advancedBusy && !root.roamingInProgress && !root.dragging) {
                root.startNextRoamCycle()
            }
        }
    }

    function startNextRoamCycle() {
        var aspect = view.width / Math.max(1, view.height)
        // Safe 3D world bounds so MAX roams freely across the screen without clipping
        var maxX = Math.max(40, 68 * aspect - 38)
        var maxY = 38

        root.targetRoamX = (Math.random() * 2 - 1) * maxX
        root.targetRoamY = (Math.random() * 2 - 1) * maxY
        roamTravelAnim.restart()
    }

    function toggleStandbyMode(enable) {
        var targetState = (typeof enable === "boolean") ? enable : !root.standbyMode
        if (targetState === root.standbyMode) return

        if (targetState) {
            // Save normal window coordinates and expand to boundary-free Fullscreen
            root.savedX = root.x
            root.savedY = root.y
            root.chatVisible = false
            root.standbyMode = true
            root.x = 0
            root.y = 0
            root.standbyAnimIndex = 0
            root.startNextRoamCycle()
        } else {
            // Stop roaming timers and return smoothly to compact mode
            roamTravelAnim.stop()
            standbyArrivalTimer.stop()
            standbyRestTimer.stop()
            root.roamingInProgress = false
            root.roamBankRoll = 0
            root.roamTurnYaw = 0
            root.roamX = 0
            root.roamY = 0
            root.approachZ = 0
            root.standbyMode = false
            root.x = root.savedX
            root.y = root.savedY
            root.currentShowcaseName = ""
            if (root.backend) root.backend.setState("idle")
            else root.updateState("idle")
        }
    }

    function playRandomIdle() {
        var idx = Math.floor(Math.random() * root.standbyAnimations.length)
        root.playNamedAnimation(root.standbyAnimations[idx])
    }


    // ========================================================
    // NAMED ANIMATION PLAYER (called from backend & standby)
    // ========================================================
    function playNamedAnimation(name) {
        if (root.advancedBusy) {
            root.advancedBusy = false
        }

        switch (name) {
        case "inspect":      rndInspect.start();      break
        case "boop":         rndBoop.start();         break
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
        case "wave":         rndWave.start();         break
        case "bow":          rndBow.start();          break
        case "peekaboo":     rndPeekaboo.start();     break
        case "dizzy":        rndDizzy.start();        break
        case "shiver":       rndShiver.start();       break
        case "heartbeat":    rndHeartbeat.start();    break
        case "levitate":     rndLevitate.start();     break
        case "moonwalk":     rndMoonwalk.start();     break
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
            if (root.standbyMode) root.toggleStandbyMode(false)
            root.moveToTopRight()
        }

        function onToggleVisibilityRequested() {
            root.visible = !root.visible
            if (root.visible && !root.standbyMode) root.moveToTopRight()
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
        rndInspect.stop(); rndBoop.stop()
        rndSpin360X.stop(); rndSpin360Y.stop(); rndBarrelRoll.stop()
        rndDiagonalTilt.stop(); rndNod.stop()
        rndLookAround.stop(); rndBounce.stop(); rndWiggle.stop()
        rndSneeze.stop(); rndStretch.stop(); rndAttention.stop()
        rndFlip.stop(); rndDance.stop()
        rndWave.stop(); rndBow.stop(); rndPeekaboo.stop()
        rndDizzy.stop(); rndShiver.stop(); rndHeartbeat.stop()
        rndLevitate.stop(); rndMoonwalk.stop()
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
        root.approachZ = 0
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

        if (state === "standby") {
            idleFloat.start(); idleYaw.start(); idleTilt.start()
            root.toggleStandbyMode(true)
            return
        }

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
            randomIdleTimer.interval = 6500
            randomIdleTimer.restart()
        }
    }


    // ========================================================
    // WINDOW HELPERS
    // ========================================================
    function moveToTopRight() {
        var scr = root.screen
        root.x = scr.width - root.normalWidth - 20
        root.y = 20
        appSettings.savedWindowX = root.x
        appSettings.savedWindowY = root.y
    }

    function snapToEdge() {
        if (root.standbyMode) return
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
        appSettings.savedWindowX = root.x
        appSettings.savedWindowY = root.y
    }


    // ========================================================
    // MOUSE AREA (DYNAMIC HITBOX FOLLOWS MAX IN STANDBY MODE)
    // ========================================================
    MouseArea {
        id: maxMouseArea
        x: root.standbyMode ? (root.roboScreenX - 130 * root.zoomFactor) : 0
        y: root.standbyMode ? (root.roboScreenY - 130 * root.zoomFactor) : 0
        width: root.standbyMode ? (260 * root.zoomFactor) : parent.width
        height: root.standbyMode ? (260 * root.zoomFactor) : view.height

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
            var gx = maxMouseArea.x + mouse.x
            var gy = maxMouseArea.y + mouse.y
            startMouseX = gx
            startMouseY = gy
            if (root.standbyMode) {
                roamTravelAnim.stop()
                standbyArrivalTimer.stop()
                standbyRestTimer.stop()
                root.roamingInProgress = false
                root.roamBankRoll = 0
                root.roamTurnYaw = 0
            }
            startWindowX = root.standbyMode ? root.roamX : root.x
            startWindowY = root.standbyMode ? root.roamY : root.y
            lastMouseX = gx
            lastMouseY = gy
            dragDistance = 0
            root.dragging = true
        }

        onPositionChanged: function(mouse) {
            var gx = maxMouseArea.x + mouse.x
            var gy = maxMouseArea.y + mouse.y

            if (pressed) {
                if (root.standbyMode) {
                    var scale3D = 185 / Math.max(1, view.height)
                    root.roamX = startWindowX + (gx - startMouseX) * scale3D
                    root.roamY = startWindowY - (gy - startMouseY) * scale3D
                } else {
                    root.x = startWindowX + (gx - startMouseX)
                    root.y = startWindowY + (gy - startMouseY)
                }
                dragDistance += Math.abs(gx - lastMouseX)
                              + Math.abs(gy - lastMouseY)
                lastMouseX = gx
                lastMouseY = gy
            } else if (hoverEnabled && !root.advancedBusy && !root.roamingInProgress
                       && root.currentState === "idle") {
                var cx = width / 2
                var cy = height / 2
                var dx = (mouse.x - cx) / cx
                var dy = (mouse.y - cy) / cy
                root.trackYaw = Math.max(-1, Math.min(1, dx)) * 16
                root.trackPitch = Math.max(-1, Math.min(1, dy)) * 9
            }
        }

        onReleased: function(mouse) {
            root.dragging = false
            if (dragDistance > 120 && !root.advancedBusy) {
                if (Math.random() < 0.5)
                    rndSpin360Y.start()
            }
            snapToEdge()
            if (root.standbyMode && !root.advancedBusy) {
                standbyRestTimer.restart()
            }
        }

        onExited: {
            root.trackYaw = 0
            root.trackPitch = 0
        }

        onClicked: function(mouse) {
            var gx = maxMouseArea.x + mouse.x
            var gy = maxMouseArea.y + mouse.y

            if (mouse.button === Qt.RightButton) {
                contextMenu.showAt(gx, gy)
                return
            }
            if (contextMenu.visible) {
                contextMenu.visible = false
                return
            }
            if (root.backend) root.backend.pokeMax()
            if (root.standbyMode && !root.advancedBusy) {
                root.playNamedAnimation("boop")
            } else {
                root.pulse = 1.08
                pokePulseTimer.restart()
            }
        }
    }


    // ========================================================
    // CONTEXT MENU
    // ========================================================
    Rectangle {
        id: contextMenu
        visible: false
        z: 100
        width: 205
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

        function handleMenuAction(act) {
            visible = false

            if (act === "reset") {
                if (root.standbyMode) root.toggleStandbyMode(false)
                root.moveToTopRight()
            } else if (act === "standby") {
                root.toggleStandbyMode()
            } else if (act === "togglechat") {
                if (root.standbyMode) root.toggleStandbyMode(false)
                if (root.chatVisible) {
                    root.closeChat()
                } else {
                    root.chatVisible = true
                    if (root.backend) root.backend.setState("listening")
                    input.forceActiveFocus()
                }
            } else if (act === "inspect") {
                if (root.backend) root.backend.playAnimation("inspect")
            } else if (act === "boop") {
                if (root.backend) root.backend.playAnimation("boop")
            } else if (act === "flip") {
                if (root.backend) root.backend.playAnimation("flip")
            } else if (act === "dance") {
                if (root.backend) root.backend.playAnimation("dance")
            } else if (act === "spin") {
                if (root.backend) root.backend.playAnimation("spin360")
            } else if (act === "moonwalk") {
                if (root.backend) root.backend.playAnimation("moonwalk")
            } else if (act === "levitate") {
                if (root.backend) root.backend.playAnimation("levitate")
            } else if (act === "peekaboo") {
                if (root.backend) root.backend.playAnimation("peekaboo")
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
                    { label: root.standbyMode ? "Exit Standby Roam" : "Standby Mode (Free Roam)", act: "standby" },
                    { label: root.chatVisible ? "Close Chat" : "Open Chat", act: "togglechat" },
                    { label: "Reset Position",       act: "reset"     },
                    { label: "Come Close (Inspect)", act: "inspect"   },
                    { label: "Camera Boop",          act: "boop"      },
                    { label: "Do a Flip",            act: "flip"      },
                    { label: "Dance",                act: "dance"     },
                    { label: "Moonwalk",             act: "moonwalk"  },
                    { label: "Levitate",             act: "levitate"  },
                    { label: "Peekaboo",             act: "peekaboo"  },
                    { label: "Spin 360",             act: "spin"      },
                    { label: "Sleep",                act: "sleep"     },
                    { label: "Celebrate",            act: "celebrate" },
                    { label: "Quit",                 act: "quit"      }
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
                        color: modelData.act === "standby" ? "#88CCFF" : "white"
                        font.pixelSize: 11
                        font.bold: modelData.act === "standby"
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
        anchors.topMargin: -10
        anchors.horizontalCenter: parent.horizontalCenter
        width: 320
        height: 96
        visible: root.chatVisible && !root.standbyMode
        opacity: (root.chatVisible && !root.standbyMode) ? 1 : 0
        scale:   (root.chatVisible && !root.standbyMode) ? 1 : 0.95

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
        interval: 220
        repeat: false
        onTriggered: root.pulse = 1.0
    }

    // ========================================================
    // START
    // ========================================================
    Component.onCompleted: {
        if (appSettings.firstRun || appSettings.savedWindowX < 0) {
            moveToTopRight()
            appSettings.firstRun = false
        } else {
            root.x = appSettings.savedWindowX
            root.y = appSettings.savedWindowY
        }
        updateState("idle")
        root.chatVisible = false
    }
}
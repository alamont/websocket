effect module WebSocket
    where { command = MyCmd, subscription = MySub }
    exposing
        ( keepAlive
        , listen
        , send
        )

{-| Web sockets make it cheaper to talk to your servers.

Connecting to a server takes some time, so with web sockets, you make that
connection once and then keep using. The major benefits of this are:

1.  It faster to send messages. No need to do a bunch of work for every single
    message.

2.  The server can push messages to you. With normal HTTP you would have to
    keep _asking_ for changes, but a web socket, the server can talk to you
    whenever it wants. This means there is less unnecessary network traffic.

The API here attempts to cover the typical usage scenarios, but if you need
many unique connections to the same endpoint, you need a different library.


# Web Sockets

@docs listen, keepAlive, send

-}

import Dict
import Process
import Task exposing (Task)
import Time exposing (Time)
import WebSocket.LowLevel as WS

-- COMMANDS


type MyCmd msg
    = Send String String String


{-| Send a message to a particular address. You might say something like this:

    send "ws://echo.websocket.org" "subprotocol" "Hello!"

**Note:** It is important that you are also subscribed to this address with
`listen` or `keepAlive`. If you are not, the web socket will be created to
send one message and then closed. Not good!

-}
send : String -> String -> String -> Cmd msg
send url protocol message =
    command (Send url protocol message)


cmdMap : (a -> b) -> MyCmd a -> MyCmd b
cmdMap _ (Send url protocol msg) =
    Send url protocol msg



-- SUBSCRIPTIONS


type MySub msg
    = Listen String String (String -> msg)
    | KeepAlive String String


{-| Subscribe to any incoming messages on a websocket. You might say something
like this:

    type Msg = Echo String | ...

    subscriptions model =
      listen "ws://echo.websocket.org" "subprotocol" Echo

**Note:** If the connection goes down, the effect manager tries to reconnect
with an exponential backoff strategy. Any messages you try to `send` while the
connection is down are queued and will be sent as soon as possible.

-}
listen : String -> String -> (String -> msg) -> Sub msg
listen url protocol tagger =
    subscription (Listen url protocol tagger)


{-| Keep a connection alive, but do not report any messages. This is useful
for keeping a connection open for when you only need to `send` messages. So
you might say something like this:

    subscriptions model =
      keepAlive "ws://echo.websocket.org" "subprotocol"

**Note:** If the connection goes down, the effect manager tries to reconnect
with an exponential backoff strategy. Any messages you try to `send` while the
connection is down are queued and will be sent as soon as possible.

-}
keepAlive : String -> String -> Sub msg
keepAlive url protocol =
    subscription (KeepAlive url protocol)


subMap : (a -> b) -> MySub a -> MySub b
subMap func sub =
    case sub of
        Listen url protocol tagger ->
            Listen url protocol (tagger >> func)

        KeepAlive url protocol ->
            KeepAlive url protocol



-- MANAGER


type alias State msg =
    { sockets : SocketsDict
    , queues : QueuesDict
    , subs : SubsDict msg
    }


type alias SocketsDict =
    Dict.Dict String (String, Connection)


type alias QueuesDict =
    Dict.Dict String (String, List String)


type alias SubsDict msg =
    Dict.Dict String ( String, List (String -> msg) )


type Connection
    = Opening Int Process.Id
    | Connected WS.WebSocket


init : Task Never (State msg)
init =
    Task.succeed (State Dict.empty Dict.empty Dict.empty)



-- HANDLE APP MESSAGES


(&>) t1 t2 =
    Task.andThen (\_ -> t2) t1

getProtocol name state = 
    case Dict.get name state.sockets of
        Nothing -> ""
        Just (protocol, _) ->
            protocol

onEffects :
    Platform.Router msg Msg
    -> List (MyCmd msg)
    -> List (MySub msg)
    -> State msg
    -> Task Never (State msg)
onEffects router cmds subs state =
    let
        sendMessagesGetNewQueues =
            sendMessagesHelp cmds state.sockets state.queues

        newSubs =
            buildSubDict subs Dict.empty

        cleanup newQueues =
            let
                newEntries : QueuesDict
                newEntries =
                    Dict.union newQueues (Dict.map (\k v -> (Tuple.first v ,[])) newSubs)

                leftStep : String -> (String, List String) -> Task x SocketsDict -> Task x SocketsDict
                leftStep name (protocol, _) getNewSockets =
                    getNewSockets
                        |> Task.andThen
                            (\newSockets ->                                
                                attemptOpen router 0 name protocol
                                    |> Task.andThen (\pid -> Task.succeed (Dict.insert name (protocol, Opening 0 pid) newSockets))
                            )

                bothStep : String -> a -> (String, Connection) -> Task x SocketsDict -> Task x SocketsDict
                bothStep name _ (protocol, connection) getNewSockets =
                    Task.map (Dict.insert name (protocol, connection)) getNewSockets

                rightStep : String -> (String, Connection) -> Task x SocketsDict -> Task x SocketsDict
                rightStep name (protocol, connection) getNewSockets =
                    closeConnection (protocol, connection) &> getNewSockets

                collectNewSockets =
                    Dict.merge leftStep bothStep rightStep newEntries state.sockets (Task.succeed Dict.empty)
            in
            collectNewSockets
                |> Task.andThen (\newSockets -> Task.succeed (State newSockets newQueues newSubs ))
    in
    sendMessagesGetNewQueues
        |> Task.andThen cleanup


sendMessagesHelp : List (MyCmd msg) -> SocketsDict -> QueuesDict -> Task x QueuesDict
sendMessagesHelp cmds socketsDict queuesDict =
    case cmds of
        [] ->
            Task.succeed queuesDict

        (Send name protocol msg) :: rest ->
            case Dict.get name socketsDict of
                Just (_, Connected socket) ->
                    WS.send socket msg
                        &> sendMessagesHelp rest socketsDict queuesDict

                _ ->
                    sendMessagesHelp rest socketsDict (Dict.update name (addTuple protocol msg) queuesDict)


buildSubDict : List (MySub msg) -> SubsDict msg -> SubsDict msg
buildSubDict subs dict =
    case subs of
        [] ->
            dict

        (Listen name protocol tagger) :: rest ->
            buildSubDict rest (Dict.update name (addTuple protocol tagger) dict)

        (KeepAlive name protocol) :: rest ->
            buildSubDict rest (Dict.update name (Just << Maybe.withDefault (protocol, [])) dict)


addTuple : String -> a -> Maybe (String, List a) -> Maybe (String, List a)
addTuple protocol tagger maybeSub =
    case maybeSub of
        Nothing ->
            Just (protocol, [ tagger ])

        Just sub ->
            Just (Tuple.first sub, tagger :: (Tuple.second sub))

add : a -> Maybe (List a) -> Maybe (List a)
add value maybeList =
    case maybeList of
        Nothing ->
            Just [ value ]

        Just list ->
            Just (value :: list)



-- HANDLE SELF MESSAGES


type Msg
    = Receive String String
    | Die String
    | GoodOpen String WS.WebSocket
    | BadOpen String


onSelfMsg : Platform.Router msg Msg -> Msg -> State msg -> Task Never (State msg)
onSelfMsg router selfMsg state =
    case selfMsg of
        Receive name str ->
            let
                sends =
                    Dict.get name state.subs
                        |> Maybe.withDefault (getProtocol name state, [])
                        |> Tuple.second
                        |> List.map (\tagger -> Platform.sendToApp router (tagger str))
            in
            Task.sequence sends &> Task.succeed state

        Die name ->
            case Dict.get name state.sockets of
                Nothing ->
                    Task.succeed state

                Just socket ->
                    let
                        protocol = Tuple.first socket
                    in
                    attemptOpen router 0 name protocol
                        |> Task.andThen (\pid -> Task.succeed (updateSocket name (protocol, Opening 0 pid) state))

        GoodOpen name socket ->
            let
                maybeSocket = Dict.get name state.sockets
                protocol = case maybeSocket of
                    Nothing -> ""
                    Just (protocol, _) ->
                        protocol
            in
            case Dict.get name state.queues of
                Nothing ->
                    
                    Task.succeed (updateSocket name (protocol, Connected socket) state)

                Just (protocol, messages) ->
                    List.foldl
                        (\msg task -> WS.send socket msg &> task)
                        (Task.succeed (removeQueue name (updateSocket name (protocol, Connected socket) state)))
                        messages

        BadOpen name ->
            case Dict.get name state.sockets of
                Nothing ->
                    Task.succeed state

                Just (protocol, Opening n _) ->
                    attemptOpen router (n + 1) name protocol
                        |> Task.andThen (\pid -> Task.succeed (updateSocket name (protocol, Opening (n + 1) pid) state))

                Just (protocol, Connected _) ->
                    Task.succeed state


updateSocket : String -> (String, Connection) -> State msg -> State msg
updateSocket name (protocol, connection) state =
    { state | sockets = Dict.insert name (protocol, connection) state.sockets }


removeQueue : String -> State msg -> State msg
removeQueue name state =
    { state | queues = Dict.remove name state.queues }



-- OPENING WEBSOCKETS WITH EXPONENTIAL BACKOFF


attemptOpen : Platform.Router msg Msg -> Int -> String -> String -> Task x Process.Id
attemptOpen router backoff name protocol =
    let
        goodOpen ws =
            Platform.sendToSelf router (GoodOpen name ws)

        badOpen _ =
            Platform.sendToSelf router (BadOpen name)

        actuallyAttemptOpen =
            open name protocol router
                |> Task.andThen goodOpen
                |> Task.onError badOpen
    in
    Process.spawn (after backoff &> actuallyAttemptOpen)


open : String -> String -> Platform.Router msg Msg -> Task WS.BadOpen WS.WebSocket
open name protocol router =
    WS.open name
        protocol
        { onMessage = \_ msg -> Platform.sendToSelf router (Receive name msg)
        , onClose = \details -> Platform.sendToSelf router (Die name)
        }


after : Int -> Task x ()
after backoff =
    if backoff < 1 then
        Task.succeed ()
    else
        Process.sleep (toFloat (10 * 2 ^ backoff))



-- CLOSE CONNECTIONS


closeConnection : (String, Connection) -> Task x ()
closeConnection (protocol, connection) =
    case connection of
        Opening _ pid ->
            Process.kill pid

        Connected socket ->
            WS.close socket

local MAJOR = 'DialUpComms';
local MINOR = 9;

local DialUpComms = LibStub:NewLibrary(MAJOR, MINOR);
if not DialUpComms then return; end;
DialUpComms.Prefix = 'DUC';

DialUpComms.IncomingPackages = {};
DialUpComms.OutgoingPackages = {};
DialUpComms.internallyRegisteredPrefixes = DialUpComms.internallyRegisteredPrefixes or {};
DialUpComms.NameToBnetGameID = {};
DialUpComms.BnetGameIDToName = {};

DialUpComms.queueTypes = {
    'URGENT', 'ALERT', 'NORMAL', 'BULK',
};

DialUpComms.prefixCount = 0;
DialUpComms.channelCooldowns = {};

DialUpComms.MessageIdLength = 2;
DialUpComms.PartNumberMessageLength = 2;

DialUpComms.HeaderPrefix = 'DUC_HEADER';
DialUpComms.ResponsePrefix = 'DUC_RESPONSE';

DialUpComms.Retries = 5;
DialUpComms.RetryInterval = 120;

--sometimes addon messages are throttled even though we're respecting the limits due to server lag
DialUpComms.LatencyBuffer = 0.01;


DialUpComms.GlobalCommLimit = {
    budget = 20,
    reset = 1,
};

DialUpComms.commLimits = {
    ['GUILD'] = {
        prefix = {
            budget = 10,
            reset = 10,
        },
        total = {
            budget = 20,
            reset = 2,
        },
        messageLength = 255,
    },
    ['WHISPER'] = {
        total = {
            budget = 20,
            reset = 1,
        },
        messageLength = 255,
    },
    ['BNET'] = {
        total = {
            budget = 3,
            reset = 3,
        },
        --capped at 4094, but takes prefix length into account
        messageLength = 4094 - (max(#DialUpComms.HeaderPrefix, #DialUpComms.Prefix)),
    },
    ['GROUP'] = {
        prefix = {
            budget = 10,
            reset = 10,
        },
        total = {
            budget = 20,
            reset = 1,
        },
        messageLength = 255,
    },
};

DialUpComms.sharedLimits = {
    ['INSTANCE_CHAT'] = 'GROUP',
    ['RAID'] = 'GROUP',
    ['PARTY'] = 'GROUP',
};

DialUpComms.ChatIsRestricted = false;
DialUpComms.CurrentRegion = GetCurrentRegion();

DialUpComms.debug = false;

local function debugPrint(...)
    if not DialUpComms.debug then return; end;
    print('|c' .. 'FF00d111' .. 'DialUpComms|r:', tostringall(...));
end;

local function registerPrefixes()
    C_ChatInfo.RegisterAddonMessagePrefix(DialUpComms.HeaderPrefix);
    C_ChatInfo.RegisterAddonMessagePrefix(DialUpComms.ResponsePrefix);
    local prefixesToRegister = 0;

    DialUpComms.channelCooldowns['GLOBAL'] = {index = 1,};

    for channel, channelLimits in pairs(DialUpComms.commLimits) do
        DialUpComms.channelCooldowns[channel] = {index = 1,};
        if channelLimits.prefix then
            local channelBudget = channelLimits.total.budget;
            local channelReset = channelLimits.total.reset;



            local prefixBudget = channelLimits.prefix.budget;
            local prefixReset = channelLimits.prefix.reset;
            local channelCommsPerSec = channelReset / channelBudget;
            local prefixCommsPerSec = prefixReset / prefixBudget;
            local additionalPrefixesRequired = math.ceil(prefixCommsPerSec / channelCommsPerSec);
            prefixesToRegister = prefixesToRegister + additionalPrefixesRequired;
        end;
    end;
    prefixesToRegister = max(prefixesToRegister, 1);
    for i = 1, prefixesToRegister do
        local result1 = C_ChatInfo.RegisterAddonMessagePrefix(DialUpComms.Prefix .. i);
        local result2 = C_ChatInfo.RegisterAddonMessagePrefix(DialUpComms.HeaderPrefix .. i);
        local result3 = C_ChatInfo.RegisterAddonMessagePrefix(DialUpComms.ResponsePrefix .. i);
        if result3 == Enum.RegisterAddonMessagePrefixResult.MaxPrefixes then
            debugPrint('Bailed early when registering prefixes', i - 1, prefixesToRegister);
            prefixesToRegister = i - 3;
            break;
        end;
    end;
    DialUpComms.prefixCount = prefixesToRegister;
    debugPrint('Registered', prefixesToRegister, 'prefixes');
    local prefixLength = #tostring(prefixesToRegister);
    DialUpComms.commLimits.BNET.messageLength = DialUpComms.commLimits.BNET.messageLength - prefixLength;
end;


function DialUpComms.OnMessageSent(prefix, channel, response, message)
    if response and response ~= Enum.SendAddonMessageResult.Success then
        return;
    end;
    local limitType = DialUpComms.sharedLimits[channel] or channel or 'GROUP';
    local cdTable = DialUpComms.channelCooldowns[limitType];
    --if not cdTable then return; end; --no cd for this channel?
    local now = GetTime();
    cdTable[cdTable.index] = now;
    cdTable.index = cdTable.index + 1;
    if cdTable.index > DialUpComms.commLimits[limitType].total.budget then
        cdTable.index = 1;
    end;

    local globalCDTable = DialUpComms.channelCooldowns['GLOBAL'];
    local globalIndex = globalCDTable.index;
    globalCDTable[globalIndex] = now;
    globalCDTable.index = globalIndex + 1;
    if globalCDTable.index > DialUpComms.GlobalCommLimit.budget then
        globalCDTable.index = 1;
    end;
end;

function DialUpComms.HookAddonMessages()
    --softhooking instead of hardhook comes with the disadvantage of not knowing the return value of a given message. depending on how blizzard handles the throttle this might not matter though
    --[[
    local oSendAddonMessage = C_ChatInfo.SendAddonMessage;
    local oSendAddonMessageLogged = C_ChatInfo.SendAddonMessageLogged;
    local oSendGameData = C_BattleNet.SendGameData;
    function C_ChatInfo.SendAddonMessage(prefix, message, channel, target)
        local response = oSendAddonMessage(prefix, message, channel, target);
        DialUpComms.OnMessageSent(prefix, channel, response, message);
        return response;
    end;

    function C_ChatInfo.SendAddonMessageLogged(prefix, message, channel, target)
        local response = oSendAddonMessageLogged(prefix, message, channel, target);
        DialUpComms.OnMessageSent(prefix, channel, response, message);
        return response;
    end;

    function C_BattleNet.SendGameData(gameAccountID, prefix, data)
        local response = oSendGameData(gameAccountID, prefix, data);
        DialUpComms.OnMessageSent(prefix, 'BNET', response, data);
        return response;
    end;
    ]] --

    hooksecurefunc(_G.C_ChatInfo, 'SendAddonMessage', function(prefix, message, channel, target)
        DialUpComms.OnMessageSent(prefix, channel, nil, message);
    end);

    hooksecurefunc(_G.C_ChatInfo, 'SendAddonMessageLogged', function(prefix, message, channel, target)
        DialUpComms.OnMessageSent(prefix, channel, nil, message);
    end);
    hooksecurefunc(_G.C_BattleNet, 'SendGameData', function(gameAccountID, prefix, data)
        DialUpComms.OnMessageSent(prefix, 'BNET', nil, data);
    end);

    --it's possible that messages were sent by other addons pre hook, fill CD table to account for the worst case scenario
    for channel, info in pairs(DialUpComms.commLimits) do
        local budget = info.total.budget;

        for i = 1, budget do
            DialUpComms.OnMessageSent(nil, channel, nil, nil);
        end;
    end;

    debugPrint('CommsAreHooked: DUC version:', MINOR);
    DialUpComms.CommsAreHooked = true;
end;

function DialUpComms.isHeaderPrefix(prefix)
    if DialUpComms.HeaderPrefix == string.sub(prefix, 1, #DialUpComms.HeaderPrefix) then return true; end;
    return false;
end;

function DialUpComms.isHeaderOrResponsePrefix(prefix)
    if DialUpComms.isHeaderPrefix(prefix) then return true; end;
    if DialUpComms.ResponsePrefix == string.sub(prefix, 1, #DialUpComms.ResponsePrefix) then return true; end;
    return false;
end;

function DialUpComms.isDUCPrefix(incomingPrefix)
    if DialUpComms.isHeaderOrResponsePrefix(incomingPrefix) then return true; end;
    local DUCPrefix = DialUpComms.Prefix;
    local DUCPrefixLength = #DUCPrefix;
    local prefix = string.sub(incomingPrefix, 1, DUCPrefixLength);
    return prefix == DUCPrefix;
end;

function DialUpComms.doesMessageExistInQueue(message, channel, target)
    for queueType, queueTable in pairs(DialUpComms.queues) do
        channel = DialUpComms.sharedLimits[channel] or channel;
        local queue = queueTable[channel];
        for i, queuedMessageInfo in ipairs(queue) do
            if not target or target == queuedMessageInfo.target then
                if message == queuedMessageInfo.message then return true; end;
            end;
        end;
    end;
    return false;
end;

local function onEvent(self, event, prefix, message, channel, sender)
    if event == 'CHAT_MSG_ADDON' or event == 'BN_CHAT_MSG_ADDON' then
        if not DialUpComms.isDUCPrefix(prefix) then return; end;
        if DialUpComms.HeaderPrefix == string.sub(prefix, 1, #DialUpComms.HeaderPrefix) then
            local messageID = string.sub(message, 1, DialUpComms.MessageIdLength);
            local numParts = string.sub(message, DialUpComms.MessageIdLength + 1, DialUpComms.MessageIdLength + DialUpComms.PartNumberMessageLength);
            local realPrefix = string.sub(message, DialUpComms.MessageIdLength + DialUpComms.PartNumberMessageLength + 1, string.find(message, ':') - 1);
            if not DialUpComms.internallyRegisteredPrefixes[realPrefix] then return; end;
            local firstMessagePart = string.sub(message, DialUpComms.MessageIdLength + DialUpComms.PartNumberMessageLength + #realPrefix + 2, #message);
            if event == 'BN_CHAT_MSG_ADDON' then
                --need to provide name as it isn't available via C_BattleNet.GetGameAccountInfoByID when 'show as offline' is enabled
                local fullName = string.sub(firstMessagePart, 1, string.find(firstMessagePart, ':') - 1);
                DialUpComms.BnetGameIDToName[sender] = fullName;
                sender = fullName;
                firstMessagePart = string.sub(firstMessagePart, #sender + 2, #firstMessagePart);
            end;
            sender = Ambiguate(sender, 'none');
            DialUpComms.PrepIncomingPackage(realPrefix, DialUpComms:DecodeNumber(numParts), messageID, sender, channel);
            DialUpComms.AddNewPart(messageID, 1, firstMessagePart, sender);
        elseif DialUpComms.ResponsePrefix == string.sub(prefix, 1, #DialUpComms.ResponsePrefix) then
            if event == 'BN_CHAT_MSG_ADDON' then
                sender = DialUpComms.BnetGameIDToName[sender];
                if not sender then return; end; --we have not interacted with this person yet
            end;
            local messageID = string.sub(message, 1, DialUpComms.MessageIdLength);
            local packetInfo = DialUpComms.OutgoingPackages[messageID];
            if not packetInfo then
                return;
            end;
            local numPartsCollected = DialUpComms:DecodeNumber(string.sub(message, DialUpComms.MessageIdLength + 1, DialUpComms.MessageIdLength + DialUpComms.PartNumberMessageLength));
            packetInfo.confirmedReceivers[sender] = numPartsCollected;
            if packetInfo.statusCallback then
                securecallfunction(packetInfo.statusCallback, packetInfo.confirmedReceivers, packetInfo.parts);
            end;
            local partsTotal = packetInfo.parts;
            if numPartsCollected > 0 and --initial response
            numPartsCollected < partsTotal then
                local messageToResend = packetInfo.partTable[numPartsCollected + 1];
                if DialUpComms.doesMessageExistInQueue(messageToResend, packetInfo.channel, packetInfo.target) then return; end;
                DialUpComms:SendOrQueueMessage(packetInfo.prefix, messageToResend, packetInfo.channel, packetInfo.target, 'ALERT');
            end;
            local receiverHasIncompletePacket = false;
            for name, parts in pairs(packetInfo.confirmedReceivers) do
                if partsTotal ~= parts then
                    receiverHasIncompletePacket = true;
                    break;
                else
                end;
            end;
            if receiverHasIncompletePacket then
                return;
            end;
            --this might prematurely clear if one guy is done b4 another guy sent his first response, is this a concern?
            DialUpComms.OutgoingPackages[messageID] = nil;
        else
            if event == 'BN_CHAT_MSG_ADDON' then
                sender = DialUpComms.BnetGameIDToName[sender];
                if not sender then return; end; --we have not interacted with this person yet
            end;
            sender = Ambiguate(sender, 'none');
            local messageID = string.sub(message, 1, DialUpComms.MessageIdLength);
            local partNumber = string.sub(message, DialUpComms.MessageIdLength + 1, DialUpComms.MessageIdLength + DialUpComms.PartNumberMessageLength);
            local messagePart = string.sub(message, DialUpComms.MessageIdLength + DialUpComms.PartNumberMessageLength + 1, #message);
            DialUpComms.AddNewPart(messageID, DialUpComms:DecodeNumber(partNumber), messagePart, sender);
        end;
    elseif event == 'PLAYER_ENTERING_WORLD' then
        --don't hardhook until we've ensured that we're up to date
        DialUpComms.ChatIsRestricted = C_ChatInfo.InChatMessagingLockdown();
        DialUpComms.HookAddonMessages();

        for queueType in pairs(DialUpComms.commLimits) do
            DialUpComms.UpdateQueueState(queueType);
        end;

        DialUpComms.CurrentRealm = GetNormalizedRealmName(); --not available instantly on login
        DialUpComms.PlayerNameFull = string.format('%s-%s', GetUnitName('player', true), DialUpComms.CurrentRealm);


        DialUpComms.Eventframe:UnregisterEvent('PLAYER_ENTERING_WORLD');
    elseif 'ADDON_RESTRICTION_STATE_CHANGED' then
        local newState = C_ChatInfo.InChatMessagingLockdown();
        if DialUpComms.ChatIsRestricted == newState then return; end;
        DialUpComms.ChatIsRestricted = newState;
        if DialUpComms.ChatIsRestricted then
            debugPrint('Chat restriction is now enforced');
            return;
        end;
        debugPrint('Chat restriction is now cleared');
        for queueType in pairs(DialUpComms.commLimits) do
            DialUpComms.UpdateQueueState(queueType);
        end;
    else
        error('DComms BAD EVENT WEEWOO');
    end;
end;



function DialUpComms.SendResponsePacket(packet)
    if DialUpComms.UnitIsPlayer(packet.sender) then return; end;

    local channel = 'WHISPER';
    if DialUpComms.CanSendToTargetViaBNET(packet.sender) then
        --channel = 'BNET';
    end;
    local id = packet.id;
    local firstMissingPiece = DialUpComms.GetFirstMissingPiece(packet);

    local partsCollected = firstMissingPiece and firstMissingPiece - 1 or packet.parts;

    local prio = 'BULK';

    if partsCollected == 0 and packet.parts ~= 1 then
        prio = 'URGENT'; -- prio initial presponse in multi message situations
    end;

    local partsCollectedEncoded = DialUpComms:EncodeParts(partsCollected);
    local fullMessage = string.format('%s%s', id, partsCollectedEncoded);

    if DialUpComms.doesMessageExistInQueue(fullMessage, channel, packet.sender) then return; end;
    DialUpComms:SendOrQueueMessage(DialUpComms.ResponsePrefix, string.format('%s%s', id, partsCollectedEncoded), channel, packet.sender, prio);
end;

function DialUpComms.GetFirstMissingPiece(pack)
    local partsTable = pack.partTable;
    for i = 1, pack.parts do
        if not partsTable[i] then return i; end;
    end;
end;

function DialUpComms.AddNewPart(ID, partNumber, message, sender)
    assert(sender);
    local key = string.format('%s%s', sender, ID);
    local pack = DialUpComms.IncomingPackages[key];
    if not pack then
        return;
    end;
    pack.partTable[partNumber] = message;


    if #pack.partTable ~= pack.parts then return; end; --doing '#'' apparently cheats and don't check for missing pieces
    local firstMissingPiece = DialUpComms.GetFirstMissingPiece(pack);
    if firstMissingPiece then
        DialUpComms.SendResponsePacket(pack);
        return;
    end;
    local fullMessage = table.concat(pack.partTable);
    if pack.retryTicker then
        pack.retryTicker:Cancel();
    end;
    DialUpComms.SendResponsePacket(pack);

    for i, func in ipairs(DialUpComms.internallyRegisteredPrefixes[pack.prefix]) do
        func(pack.prefix, fullMessage, pack.channel, pack.sender);
    end;
    DialUpComms.IncomingPackages[key] = nil;
    if pack.parts > 1 then
        debugPrint('Packet from', pack.sender, 'channel', pack.channel, 'completed. length:', #fullMessage);
    end;
end;

function DialUpComms.PrepIncomingPackage(prefix, parts, ID, sender, channel)
    local pack = {};
    pack.parts = parts;
    pack.prefix = prefix;
    pack.id = ID;
    pack.startTime = GetTime();
    pack.sender = sender;
    pack.channel = channel;
    pack.partTable = {};
    pack.key = string.format('%s%s', sender, ID);
    DialUpComms.IncomingPackages[pack.key] = pack;
    if pack.parts == 1 then return; end;
    DialUpComms.SendResponsePacket(pack);
    pack.retriesLeft = DialUpComms.Retries;
    pack.retryTicker =
        C_Timer.NewTicker(
            DialUpComms.RetryInterval,
            function()
                if not DialUpComms.AddonCommsCurrentlyAllowed() then return; end;
                if not DialUpComms.GetFirstMissingPiece(pack) then
                    pack.retryTicker:Cancel();
                    return;
                end;
                pack.retriesLeft = pack.retriesLeft - 1;
                if pack.retriesLeft < 1 then
                    pack.retryTicker:Cancel();
                end;
                debugPrint('Requesting missing piece from', sender, 'channel', channel, 'retries left', pack.retriesLeft, 'packetID', ID);
                DialUpComms.SendResponsePacket(pack);
            end
        );
    debugPrint('Incoming multi part packet from', sender, 'channel', channel, 'parts', parts, 'prefix', prefix);
end;

function DialUpComms.getGlobalCDForChannel(channel)
    local limitType = DialUpComms.sharedLimits[channel] or channel;
    local cdTable = DialUpComms.channelCooldowns[limitType];
    local totalIndex = cdTable.index;
    local totalCooldown = cdTable[totalIndex] or 0;
    local totalReset = DialUpComms.commLimits[limitType].total.reset;
    return totalCooldown + totalReset + DialUpComms.LatencyBuffer;
end;

function DialUpComms.getGlobalCD()
    local cdTable = DialUpComms.channelCooldowns['GLOBAL'];
    local totalIndex = cdTable.index;
    local totalCooldown = cdTable[totalIndex] or 0;
    local totalReset = DialUpComms.GlobalCommLimit.reset;
    return totalCooldown + totalReset + DialUpComms.LatencyBuffer;
end;

function DialUpComms.canSendMessageInChannel(channel)
    if not DialUpComms.AddonCommsCurrentlyAllowed() then return false; end;
    local cd = DialUpComms.getGlobalCDForChannel(channel);
    local globalCD = DialUpComms.getGlobalCD();
    local now = GetTime();
    return cd < now and globalCD < now;
end;

function DialUpComms.getNextPrefixIndexForChannel(channel)
    local limitType = DialUpComms.sharedLimits[channel] or channel;
    local cdTable = DialUpComms.channelCooldowns[limitType];
    local index = cdTable.index;
    local count = DialUpComms.prefixCount;
    local prefixIndex = index % count + 1;
    return prefixIndex;
end;

function DialUpComms.init()
    DialUpComms.setupQueues();
    registerPrefixes();

    DialUpComms.Eventframe = DialUpComms.Eventframe or CreateFrame('Frame');
    DialUpComms.Eventframe:UnregisterAllEvents();
    DialUpComms.Eventframe:RegisterEvent('PLAYER_ENTERING_WORLD');
    DialUpComms.Eventframe:RegisterEvent('CHAT_MSG_ADDON');
    DialUpComms.Eventframe:RegisterEvent('BN_CHAT_MSG_ADDON');
    DialUpComms.Eventframe:RegisterEvent('ADDON_RESTRICTION_STATE_CHANGED');
    DialUpComms.Eventframe:SetScript('OnEvent', onEvent);
end;

function DialUpComms.getMaxMessageLengthForChannel(channel)
    channel = DialUpComms.sharedLimits[channel] or channel;
    return DialUpComms.commLimits[channel].messageLength;
end;

function DialUpComms.SendMessageInternal(incomingPrefix, message, channel, target, callbackFunction, callbackArgument, bytesSent, totalAmountOfBytesToSend)
    local prefix;
    if not DialUpComms.isHeaderOrResponsePrefix(incomingPrefix) then
        prefix = DialUpComms.Prefix .. DialUpComms.getNextPrefixIndexForChannel(channel);
        debugPrint('Sending message with internal prefix', incomingPrefix, 'real prefix:', prefix, 'channel', channel, channel == 'WHISPER' and target or '');
    else
        prefix = incomingPrefix .. DialUpComms.getNextPrefixIndexForChannel(channel);

        if DialUpComms.isHeaderPrefix(prefix) then
            debugPrint('Sending header with internal prefix', incomingPrefix, 'real prefix:', prefix, 'channel', channel, channel == 'WHISPER' and target or '');
        end;
    end;

    local response;
    if channel == 'BNET' then
        local gameId = DialUpComms.GetBNETGameIDForTarget(target); -- tf do we do if gameId isn't available here
        if gameId then
            response = C_BattleNet.SendGameData(gameId, prefix, message);
        end;
    else
        response = C_ChatInfo.SendAddonMessage(prefix, message, channel, target);
    end;
    if response ~= Enum.SendAddonMessageResult.Success then
        debugPrint('Sending Comm FAILED. Response:', response, 'channel', channel, 'messageLength', #message, 'target', target, 'prefixLength', #prefix);

        --these should never happen
        assert(response ~= Enum.SendAddonMessageResult.InvalidChatType, 'InvalidChatType');
        assert(response ~= Enum.SendAddonMessageResult.InvalidChannel, 'InvalidChannel');
        assert(response ~= Enum.SendAddonMessageResult.InvalidMessage, 'InvalidMessage');
        assert(response ~= Enum.SendAddonMessageResult.InvalidPrefix, 'InvalidPrefix');
        assert(response ~= Enum.SendAddonMessageResult.TargetRequired, 'TargetRequired');
        assert(response ~= Enum.SendAddonMessageResult.AddonMessageThrottle, 'AddonMessageThrottle');
        --assert(response ~= Enum.SendAddonMessageResult.AddOnMessageLockdown, 'AddOnMessageLockdown');
        assert(response ~= Enum.SendAddonMessageResult.ChannelThrottle, 'ChannelThrottle');

        if channel == 'BNET' then --don't bother with bnet again
            response = Enum.SendAddonMessageResult.GeneralError;
            channel = 'WHISPER';
        end;
        if (response == Enum.SendAddonMessageResult.TargetOffline or
            response == Enum.SendAddonMessageResult.NotInGroup or
            response == Enum.SendAddonMessageResult.NotInGuild) then
            return;
        end;

        --retry asap
        debugPrint('Requeue message due to failure', incomingPrefix, channel, target and target or '');
        DialUpComms:SendOrQueueMessage(incomingPrefix, message, channel, target, 'URGENT', callbackFunction, callbackArgument, bytesSent, totalAmountOfBytesToSend);
        return;
    end;
    if callbackFunction then
        securecallfunction(callbackFunction, callbackArgument, bytesSent, totalAmountOfBytesToSend);
    end;
end;

function DialUpComms.UpdateQueueState(channel)
    if not DialUpComms.canSendMessageInChannel(channel) then
        DialUpComms.ScheduleUpdate(channel);
        return;
    end;

    for i, prio in ipairs(DialUpComms.queueTypes) do
        local queue = DialUpComms.queues[prio][channel];
        local messageToSend = queue[1];
        if messageToSend then
            DialUpComms.SendMessageInternal(messageToSend.prefix, messageToSend.message, messageToSend.channel, messageToSend.target, messageToSend.callbackFunction, messageToSend.callbackArgument, messageToSend.bytesSent,
                                            messageToSend.totalAmountOfBytesToSend);
            table.remove(queue, 1);
            if #queue == 0 then
                debugPrint(string.format('%s %s queue emptied', prio, channel));
            end;
            return DialUpComms.UpdateQueueState(channel);
        end;
    end;
end;

function DialUpComms.ScheduleUpdate(channel)
    if not DialUpComms.AddonCommsCurrentlyAllowed() then
        debugPrint('Did not schedule update due to chat restriction', channel);
        return false;
    end;
    if DialUpComms.timers[channel] then
        --debugPrint('Did not schedule update due to timer already existing. Channel', channel);
        return false;
    end;


    local channelAvailableTime = math.max(DialUpComms.getGlobalCDForChannel(channel), DialUpComms.getGlobalCD());
    local now = GetTime();
    local timeUntilAvailable = (channelAvailableTime - now);
    DialUpComms.timers[channel] = C_Timer.NewTimer(timeUntilAvailable, function()
        DialUpComms.timers[channel] = nil;
        DialUpComms.UpdateQueueState(channel);
    end);
    debugPrint('Scheduled update happening in', timeUntilAvailable, 'seconds', 'channel', channel);
end;

function DialUpComms:QueueMessage(prefix, message, channel, target, priority, callbackFunction, callbackArgument, bytesSent, totalAmountOfBytesToSend)
    local channelQueue = DialUpComms.sharedLimits[channel] or channel;
    local queue = DialUpComms.queues[priority][channelQueue];
    queue[#queue+1] = {
        prefix = prefix,
        message = message,
        channel = channel,
        target = target,
        callbackFunction = callbackFunction,
        callbackArgument = callbackArgument,
        bytesSent = bytesSent,
        totalAmountOfBytesToSend = totalAmountOfBytesToSend,
    };
    --debugPrint('Queueing message for prefix', prefix, 'prio', priority, 'channel', channel, '. Current queue length', #queue);
    DialUpComms.ScheduleUpdate(channelQueue);
end;

function DialUpComms:SendOrQueueMessage(prefix, message, channel, target, priority, callbackFunction, callbackArgument, bytesSent, totalAmountOfBytesToSend)
    if not DialUpComms.canSendMessageInChannel(channel) then
        DialUpComms:QueueMessage(prefix, message, channel, target, priority, callbackFunction, callbackArgument, bytesSent, totalAmountOfBytesToSend);
        return;
    end;
    DialUpComms.SendMessageInternal(prefix, message, channel, target, callbackFunction, callbackArgument, bytesSent, totalAmountOfBytesToSend);
end;

local function getCharacterNameFromAccountInfo(accountInfo)
    if not accountInfo then return; end;
    if not accountInfo.regionID then return; end;
    local matchesMyRegion = accountInfo.regionID == DialUpComms.CurrentRegion;
    if not matchesMyRegion then return; end;
    local name = accountInfo.characterName;
    local realm = accountInfo.realmName;
    return name, realm;
end;


local function getBNETInfoForTarget(target)
    if DialUpComms.NameToBnetGameID[target] then
        local accountInfo = C_BattleNet.GetGameAccountInfoByID(DialUpComms.NameToBnetGameID[target]);

        if accountInfo then
            debugPrint(string.format('found bnetInfo for %s via cached id', target));
            return accountInfo;
        end;
    end;
    local unitGUID = UnitGUID(target);
    if unitGUID then
        local accountInfo = C_BattleNet.GetGameAccountInfoByGUID(unitGUID);

        if accountInfo then
            DialUpComms.NameToBnetGameID[target] = accountInfo.gameAccountID;
            debugPrint(string.format('found bnetInfo for %s via GUID', target));
            return accountInfo;
        end;
    end;

    local myRealm = GetNormalizedRealmName();
    for friendIndex = 0, BNGetNumFriends() do
        local accIndexes = C_BattleNet.GetFriendNumGameAccounts(friendIndex);
        for accountIndex = 1, accIndexes do
            local accountInfo = C_BattleNet.GetFriendGameAccountInfo(friendIndex, accountIndex);

            local name, realm = getCharacterNameFromAccountInfo(accountInfo);
            if name then
                local realmIncludedName = realm and string.format('%s-%s', name, realm) or string.format('%s-%s', name, myRealm);
                if target == realmIncludedName or target == name then
                    DialUpComms.NameToBnetGameID[realmIncludedName] = accountInfo.gameAccountID;
                    DialUpComms.NameToBnetGameID[name] = accountInfo.gameAccountID;
                    return accountInfo;
                end;
            end;
        end;
    end;
end;

function DialUpComms.GetBNETGameIDForTarget(target)
    if DialUpComms.NameToBnetGameID[target] then return DialUpComms.NameToBnetGameID[target]; end;
    local accountInfo = getBNETInfoForTarget(target);
    if not accountInfo then return; end;
    return accountInfo.gameAccountID;
end;

--we cannot cache this one since we need to know if the receiver is online
function DialUpComms.CanSendToTargetViaBNET(target)
    return getBNETInfoForTarget(target) and true or false;
end;

function DialUpComms.IsMessageValid(prefix, message, channel, target, priority, callbackFunction, callbackArgument, statusCallback, spaceInHeader)
    if not prefix then return 'Prefix missing'; end;
    if not message then return 'Message missing'; end;
    if not channel then return 'Channel missing'; end;
    if issecretvalue(message) then return 'Message is secret'; end;

    if not DialUpComms.commLimits[channel] and not DialUpComms.sharedLimits[channel] then
        return string.format('Invalid channel: %s', channel);
    end;

    if statusCallback and type(statusCallback) ~= 'function' then
        return 'statusCallback is not a function';
    end;

    if callbackFunction and type(callbackFunction) ~= 'function' then
        return 'callbackFunction is not a function';
    end;

    if channel == 'WHISPER' then
        if not target then return 'No WHISPER target'; end;
        if issecretvalue(target) then return 'WHISPER target is secret'; end;
    end;

    if spaceInHeader < 0 then return 'Prefix is too long'; end;
end;

---comment
---@param prefix string
---@param message string
---@param channel "WHISPER"| "GUILD" | "BNET" | "INSTANCE_CHAT" | "RAID" | "PARTY"
---@param target string?
---@param priority "ALERT" | "NORMAL" | 'BULK' | nil
---@param callbackFunction function | nil
---@param callbackArgument any
---@param statusCallback function | nil
function DialUpComms:SendCommMessage(prefix, message, channel, target, priority, callbackFunction, callbackArgument, statusCallback)
    priority = priority or 'NORMAL';

    if channel == 'WHISPER' and DialUpComms.CanSendToTargetViaBNET(target) then
        --channel = 'BNET';
    end;

    local messageID = DialUpComms.GenerateUniqueID();
    local totalMessageLength = #message;
    local headerLength = DialUpComms.MessageIdLength + DialUpComms.PartNumberMessageLength + #prefix + 1; --we're separating prefix and first message with a semicolon
    local maxLength = DialUpComms.getMaxMessageLengthForChannel(channel);
    local spaceInHeader = maxLength - headerLength;

    if channel == 'BNET' then
        spaceInHeader = spaceInHeader - (#DialUpComms.PlayerNameFull + 1); --need to provide character name in bnet messages
    end;

    local errorMessage = DialUpComms.IsMessageValid(prefix, message, channel, target, priority, callbackFunction, callbackArgument, statusCallback, spaceInHeader);
    if errorMessage then
        error(errorMessage);
    end;

    local parts = 1;

    local partToSendWithHeader = string.sub(message, 1, spaceInHeader);
    local bytesSent = #partToSendWithHeader;

    message = string.sub(message, spaceInHeader + 1, #message);
    local messageLength = #message;
    parts = parts + math.ceil(
        messageLength /
        (
            maxLength -
            DialUpComms.MessageIdLength -
            DialUpComms.PartNumberMessageLength
        ));


    local partsEncoded = DialUpComms:EncodeParts(parts);

    if #partsEncoded > DialUpComms.PartNumberMessageLength then error('Message is too long'); end;

    local headerPrio = parts == 1 and priority or 'ALERT';

    debugPrint('Outgoing message via prefix', prefix, 'length:', totalMessageLength, 'parts:', parts);

    local headerMessage;
    if channel == 'BNET' then
        headerMessage = string.format('%s%s%s:%s:%s', messageID, partsEncoded, prefix, DialUpComms.PlayerNameFull, partToSendWithHeader);
    else
        headerMessage = string.format('%s%s%s:%s', messageID, partsEncoded, prefix, partToSendWithHeader);
    end;
    DialUpComms:SendOrQueueMessage(DialUpComms.HeaderPrefix, headerMessage, channel, target, headerPrio, callbackFunction, callbackArgument, bytesSent, totalMessageLength);



    DialUpComms.OutgoingPackages[messageID] = {
        id = messageID,
        partTable = {headerMessage,},
        target = target,
        channel = channel,
        prefix = prefix,
        startTime = GetTime(),
        confirmedReceivers = {},
        parts = parts,
        statusCallback = statusCallback,
    };

    C_Timer.After(
        DialUpComms.RetryInterval * (DialUpComms.Retries + 1),
        function()
            if not DialUpComms.OutgoingPackages[messageID] then return; end;
            DialUpComms.OutgoingPackages[messageID] = nil;
            debugPrint('Clearing', messageID, 'due to timeout');
        end
    );


    local cursor = 0;
    local textLengthPerMessage = maxLength - #messageID - #partsEncoded;
    for partNumber = 2, parts, 1 do
        local encodedPartNumber = DialUpComms:EncodeParts(partNumber);

        local messagePart = string.sub(message, 1 + cursor, textLengthPerMessage + cursor);
        cursor = cursor + textLengthPerMessage;
        local messageToSend = string.format('%s%s%s', messageID, encodedPartNumber, messagePart);
        DialUpComms.OutgoingPackages[messageID].partTable[partNumber] = messageToSend;

        bytesSent = bytesSent + #messagePart;
        DialUpComms:SendOrQueueMessage(prefix, messageToSend, channel, target, priority, callbackFunction, callbackArgument, bytesSent, totalMessageLength);
    end;
end;

function DialUpComms.setupQueues()
    DialUpComms.timers = DialUpComms.timers or {};
    DialUpComms.queues = DialUpComms.queues or {};
    for i, queueName in ipairs(DialUpComms.queueTypes) do
        DialUpComms.queues[queueName] = DialUpComms.queues[queueName] or {};
        for limitGroup in pairs(DialUpComms.commLimits) do
            DialUpComms.queues[queueName][limitGroup] = DialUpComms.queues[queueName][limitGroup] or {};
        end;
    end;
end;

function DialUpComms:RegisterComm(prefix, func)
    DialUpComms.internallyRegisteredPrefixes[prefix] = DialUpComms.internallyRegisteredPrefixes[prefix] or {};
    table.insert(DialUpComms.internallyRegisteredPrefixes[prefix], func);
end;

DialUpComms.init();

DialUpComms.strchar = {};

--base254 because  string.char(0) and string.char(1) cannot be sent over chat channels
for i = 2, 255 do
    local symbol = string.char(i);
    DialUpComms.strchar[i - 2] = symbol;
end;

DialUpComms.strbyte = {};
for i, symbol in pairs(DialUpComms.strchar) do
    DialUpComms.strbyte[symbol] = i;
end;



function DialUpComms:DecodeNumber(number)
    local result = 0;

    for i = 1, #number do
        local char = number:sub(i, i);
        local value = DialUpComms.strbyte[char];

        result = result * 254 + value;
    end;

    return result;
end;

function DialUpComms:EncodeNumber(number)
    local ret = '';

    while number > 0 do
        local remainder = number % 254;
        local symbol = DialUpComms.strchar[remainder];
        ret = symbol .. ret;
        number = math.floor(number / 254);
    end;
    return ret;
end;

function DialUpComms:EncodeParts(number)
    number = DialUpComms:EncodeNumber(number);
    while #number < DialUpComms.PartNumberMessageLength do
        number = DialUpComms.strchar[0] .. number;
    end;
    return number;
end;

function DialUpComms.GenerateUniqueID()
    local ret = DialUpComms:EncodeNumber(math.random(0, 254 ^ DialUpComms.MessageIdLength));

    while #ret < DialUpComms.MessageIdLength do
        ret = DialUpComms.strchar[0] .. ret;
    end;
    return ret;
end;

function DialUpComms.AddonCommsCurrentlyAllowed()
    if not DialUpComms.CommsAreHooked then return false; end;
    return not DialUpComms.ChatIsRestricted;
end;

function DialUpComms.UnitIsPlayer(name)
    name = Ambiguate(name, 'none');
    return UnitIsUnit(name, 'player');
end;

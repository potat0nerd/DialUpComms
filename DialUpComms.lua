local MAJOR = 'DialUpComms';
local MINOR = 1;

local DialUpComms = LibStub:NewLibrary(MAJOR, MINOR);
if not DialUpComms then return; end;
DialUpComms.Prefix = 'DUC';

DialUpComms.IncomingPackages = {};
DialUpComms.OutgoingPackages = {};
DialUpComms.internallyRegisteredPrefixes = DialUpComms.internallyRegisteredPrefixes or {};

DialUpComms.queueTypes = {
    'ALERT', 'NORMAL', 'BULK',
};

DialUpComms.prefixCount = 0;
DialUpComms.channelCooldowns = {};

DialUpComms.MessageIdLength = 2;
DialUpComms.PartNumberMessageLength = 2;

DialUpComms.HeaderPrefix = 'DUC_HEADER';
DialUpComms.ResponsePrefix = 'DUC_RESPONSE';

DialUpComms.Retries = 60;
DialUpComms.RetryInerval = 10;

DialUpComms.commLimits = {
    ['GUILD'] = {prefix = {budget = 10, reset = 10,}, total = {budget = 20, reset = 2,}, messageLength = 255,},
    ['WHISPER'] = {prefix = {budget = 10, reset = 10,}, total = {budget = 10, reset = 10,}, messageLength = 255,},
    ['BNET'] = {prefix = {budget = 10, reset = 10,}, total = {budget = 20, reset = 2,}, messageLength = 4090,},
    ['GROUP'] = {prefix = {budget = 10, reset = 10,}, total = {budget = 20, reset = 2,}, messageLength = 255,},
};

DialUpComms.sharedLimits = {
    ['INSTANCE_CHAT'] = 'GROUP',
    ['RAID'] = 'GROUP',
    ['PARTY'] = 'GROUP',
};

DialUpComms.ChatIsRestricted = false;


local function registerPrefixes()
    C_ChatInfo.RegisterAddonMessagePrefix(DialUpComms.HeaderPrefix);
    C_ChatInfo.RegisterAddonMessagePrefix(DialUpComms.ResponsePrefix);
    local prefixesToRegister = 0;
    for channel, channelLimits in pairs(DialUpComms.commLimits) do
        DialUpComms.channelCooldowns[channel] = {index = 1,};
        local channelBudget = channelLimits.total.budget;
        local channelReset = channelLimits.total.reset;

        local prefixBudget = channelLimits.prefix.budget;
        local prefixReset = channelLimits.prefix.reset;

        local channelCommsPerSec = channelReset / channelBudget;
        local prefixCommsPerSec = prefixReset / prefixBudget;

        local prefixesRequired = math.ceil(prefixCommsPerSec / channelCommsPerSec);
        if prefixesRequired > prefixesToRegister then
            prefixesToRegister = prefixesRequired;
        end;
    end;

    for i = 1, prefixesToRegister do
        local result = C_ChatInfo.RegisterAddonMessagePrefix(DialUpComms.Prefix .. i);
        if result == Enum.RegisterAddonMessagePrefixResult.MaxPrefixes then
            --print(DialUpComms, 'bailed early when registering prefixes', i - 1, prefixesToRegister);
            prefixesToRegister = i - 1;
            break;
        end;
    end;
    DialUpComms.prefixCount = prefixesToRegister;
end;


function DialUpComms.OnMessageSent(prefix, channel, response, message)
    if response and response ~= Enum.SendAddonMessageResult.Success then
        return;
    end;
    local limitType = DialUpComms.sharedLimits[channel] or channel;
    local cdTable = DialUpComms.channelCooldowns[limitType];
    if not cdTable then return; end; --no cd for this channel?
    cdTable[cdTable.index] = GetTime();
    cdTable.index = cdTable.index + 1;
    if cdTable.index > DialUpComms.commLimits[limitType].total.budget then
        cdTable.index = 1;
    end;
end;

function DialUpComms.HookAddonMessages()
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

    DialUpComms.CommsAreHooked = true;
end;

function DialUpComms.isHeaderOrResponsePrefix(prefix)
    if DialUpComms.HeaderPrefix == prefix then return true; end;
    if DialUpComms.ResponsePrefix == prefix then return true; end;
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
    if event == 'CHAT_MSG_ADDON' then
        if not DialUpComms.isDUCPrefix(prefix) then return; end;
        sender = Ambiguate(sender, 'none');
        if prefix == DialUpComms.HeaderPrefix then
            local messageID = string.sub(message, 1, DialUpComms.MessageIdLength);
            local numParts = string.sub(message, DialUpComms.MessageIdLength + 1, DialUpComms.MessageIdLength + DialUpComms.PartNumberMessageLength);
            local realPrefix = string.sub(message, DialUpComms.MessageIdLength + DialUpComms.PartNumberMessageLength + 1, string.find(message, ':') - 1);
            if not DialUpComms.internallyRegisteredPrefixes[realPrefix] then return; end;
            local firstMessagePart = string.sub(message, DialUpComms.MessageIdLength + DialUpComms.PartNumberMessageLength + #realPrefix + 2, #message);

            DialUpComms.PrepIncomingPackage(realPrefix, DialUpComms:DecodeNumber(numParts), messageID, sender, channel);
            DialUpComms.AddNewPart(messageID, 1, firstMessagePart);
        elseif prefix == DialUpComms.ResponsePrefix then
            local messageID = string.sub(message, 1, DialUpComms.MessageIdLength);

            local packetInfo = DialUpComms.OutgoingPackages[messageID];
            if not packetInfo then
                return;
            end;

            local numPartsCollected = DialUpComms:DecodeNumber(string.sub(message, DialUpComms.MessageIdLength + 1, DialUpComms.MessageIdLength + DialUpComms.PartNumberMessageLength));
            packetInfo.confirmedRecievers[sender] = numPartsCollected;
            if packetInfo.statusCallback then
                securecallfunction(packetInfo.statusCallback, packetInfo.confirmedRecievers, packetInfo.parts);
            end;
            local partsTotal = packetInfo.parts;
            if numPartsCollected > 0 and --initial response
            numPartsCollected < partsTotal then
                local messageToResend = packetInfo.partTable[numPartsCollected + 1];
                if DialUpComms.doesMessageExistInQueue(messageToResend, packetInfo.channel, packetInfo.target) then return; end;
                DialUpComms:SendOrQueueMessage(packetInfo.prefix, messageToResend, packetInfo.channel, packetInfo.target, 'ALERT');
            end;
            local recieverHasIncompletePacket = false;
            for name, parts in pairs(packetInfo.confirmedRecievers) do
                if partsTotal ~= parts then
                    recieverHasIncompletePacket = true;
                    break;
                else
                end;
            end;
            if recieverHasIncompletePacket then
                return;
            end;
            --this might prematurely clear if one guy is done b4 another guy sent his first response, is this a concern?
            DialUpComms.OutgoingPackages[messageID] = nil;
        else
            local messageID = string.sub(message, 1, DialUpComms.MessageIdLength);
            local partNumber = string.sub(message, DialUpComms.MessageIdLength + 1, DialUpComms.MessageIdLength + DialUpComms.PartNumberMessageLength);
            local messagePart = string.sub(message, DialUpComms.MessageIdLength + DialUpComms.PartNumberMessageLength + 1, #message);
            DialUpComms.AddNewPart(messageID, DialUpComms:DecodeNumber(partNumber), messagePart);
        end;
    elseif event == 'BN_CHAT_MSG_ADDON' then
        if not DialUpComms.isDUCPrefix(prefix) then return; end;
    elseif event == 'PLAYER_ENTERING_WORLD' then
        --don't hardhook until we've ensured that we're up to date
        DialUpComms.ChatIsRestricted = C_ChatInfo.InChatMessagingLockdown();
        DialUpComms.HookAddonMessages();

        for queueType in pairs(DialUpComms.commLimits) do
            DialUpComms.UpdateQueueState(queueType);
        end;
    elseif 'ADDON_RESTRICTION_STATE_CHANGED' then
        DialUpComms.ChatIsRestricted = C_ChatInfo.InChatMessagingLockdown();
        if DialUpComms.ChatIsRestricted then return; end;
        for queueType in pairs(DialUpComms.commLimits) do
            DialUpComms.UpdateQueueState(queueType);
        end;
    else
        error('DComms BAD EVENT WEEWOO');
    end;
end;

function DialUpComms.SendResponsePacket(packet)
    local channel = 'WHISPER';
    if channel == 'WHISPER' and DialUpComms.CanSendToTargetViaBNET(packet.sender) then
        --channel = "BNET"
    end;
    local prio = 'ALERT'; --TODO should probably be bulk
    local id = packet.id;
    local firstMissingPiece = DialUpComms.GetFirstMissingPiece(packet);
    firstMissingPiece = firstMissingPiece and firstMissingPiece - 1;
    local partsCollected = firstMissingPiece or packet.parts;
    local partsCollectedEncoded = DialUpComms:EncodeParts(partsCollected);

    DialUpComms:SendOrQueueMessage(DialUpComms.ResponsePrefix, string.format('%s%s', id, partsCollectedEncoded), channel, packet.sender, prio);
end;

function DialUpComms.GetFirstMissingPiece(pack)
    local partsTable = pack.partTable;
    for i = 1, pack.parts do
        if not partsTable[i] then return i; end;
    end;
end;

function DialUpComms.AddNewPart(ID, partNumber, message)
    local pack = DialUpComms.IncomingPackages[ID];
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

    local incomingQueueCount = 0;
    for i, _ in pairs(DialUpComms.IncomingPackages) do
        incomingQueueCount = incomingQueueCount + 1;
    end;
    for i, func in ipairs(DialUpComms.internallyRegisteredPrefixes[pack.prefix]) do
        func(pack.prefix, fullMessage, pack.channel, pack.sender);
    end;
    DialUpComms.IncomingPackages[ID] = nil;
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
    DialUpComms.IncomingPackages[ID] = pack;
    if pack.parts == 1 then return; end;
    DialUpComms.SendResponsePacket(pack);
    pack.retriesLeft = DialUpComms.Retries;
    pack.retryTicker =
        C_Timer.NewTicker(
            DialUpComms.RetryInerval,
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
                DialUpComms.SendResponsePacket(pack);
            end
        );
end;

function DialUpComms.getGlobalCDForChannel(channel)
    local limitType = DialUpComms.sharedLimits[channel] or channel;
    local cdTable = DialUpComms.channelCooldowns[limitType];
    local totalIndex = cdTable.index;
    local totalCooldown = cdTable[totalIndex] or 0;
    local totalReset = DialUpComms.commLimits[limitType].total.reset;
    return totalCooldown + totalReset;
end;

function DialUpComms.canSendMessageInChannel(channel)
    if not DialUpComms.AddonCommsCurrentlyAllowed() then return false; end;
    if not DialUpComms.CommsAreHooked then return false; end;
    local cd = DialUpComms.getGlobalCDForChannel(channel);
    if not cd then return true; end;
    local now = GetTime();
    return cd <= now;
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

function DialUpComms.SendMessageInternal(prefix, message, channel, target, callbackFunction, callbackArgument, arg2, arg3)
    if not DialUpComms.isHeaderOrResponsePrefix(prefix) then
        prefix = DialUpComms.Prefix .. DialUpComms.getNextPrefixIndexForChannel(channel);
    end;
    local response = C_ChatInfo.SendAddonMessage(prefix, message, channel, target);
    if response ~= 0 then
        --print('response: ', response);
        return;
    end;
    if callbackFunction then
        securecallfunction(callbackFunction, callbackArgument, arg2, arg3);
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
            return DialUpComms.UpdateQueueState(channel);
        end;
    end;
end;

function DialUpComms.ScheduleUpdate(channel)
    if not DialUpComms.AddonCommsCurrentlyAllowed() then return false; end;
    if not DialUpComms.CommsAreHooked then return false; end;
    if DialUpComms.timers[channel] then return; end;
    local channelAvailableTime = DialUpComms.getGlobalCDForChannel(channel);
    local now = GetTime();
    local timeUntilAvailable = channelAvailableTime - now;
    DialUpComms.timers[channel] = C_Timer.NewTimer(timeUntilAvailable, function()
        DialUpComms.timers[channel] = nil;
        DialUpComms.UpdateQueueState(channel);
    end);
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
    DialUpComms.ScheduleUpdate(channelQueue);
end;

function DialUpComms:SendOrQueueMessage(prefix, message, channel, target, priority, callbackFunction, callbackArgument, bytesSent, totalAmountOfBytesToSend)
    if not DialUpComms.canSendMessageInChannel(channel) then
        DialUpComms:QueueMessage(prefix, message, channel, target, priority, callbackFunction, callbackArgument, bytesSent, totalAmountOfBytesToSend);
        return;
    end;
    DialUpComms.SendMessageInternal(prefix, message, channel, target, callbackFunction, callbackArgument, bytesSent, totalAmountOfBytesToSend);
end;

function DialUpComms.GetBNETGameIDForTarget(target)
    --TODO add this
end;

function DialUpComms.CanSendToTargetViaBNET(target)
    for i = 0, BNGetNumFriends() do
        local accIndexes = C_BattleNet.GetFriendNumGameAccounts(i);

        for j = 1, accIndexes do
            local accountInfo = C_BattleNet.GetFriendGameAccountInfo(i, j);
            if accountInfo then
                local name = accountInfo.characterName;
                if name then
                    if target == name then return true; end;
                    local realm = accountInfo.realmName;
                    local realmIncludedName = string.format('%s-%s', name, realm or GetNormalizedRealmName());
                    if target == realmIncludedName then return true; end;
                end;
            end;
        end;
    end;
end;

function DialUpComms:SendCommMessage(prefix, message, channel, target, priority, callbackFunction, callbackArgument, statusCallback)
    assert(prefix, 'Prefix Missing');
    assert(message, 'Message Missing');
    if callbackFunction and type(callbackFunction) ~= 'function' then
        error('callbackFunction is not a function');
    end;
    priority = priority or 'NORMAL';
    if channel == 'WHISPER' then
        assert(target, 'No WHISPER target');
        if DialUpComms.CanSendToTargetViaBNET(target) then
            --channel = "BNET"
        end;
    end;
    local messageID = DialUpComms.GenerateUniqueID();
    local totalMessageLength = #message;
    local headerLength = DialUpComms.MessageIdLength + DialUpComms.PartNumberMessageLength + #prefix + 1; --we're separating prefix and first message with a semicolon
    local maxLength = DialUpComms.getMaxMessageLengthForChannel(channel);
    local spaceInHeader = maxLength - headerLength;
    assert(spaceInHeader > 0, 'Prefix too long');


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
    assert(#partsEncoded <= DialUpComms.PartNumberMessageLength, 'Message is too long');




    local headerMessage = string.format('%s%s%s:%s', messageID, partsEncoded, prefix, partToSendWithHeader);
    DialUpComms:SendOrQueueMessage(DialUpComms.HeaderPrefix, headerMessage, channel, target, 'ALERT', callbackFunction, callbackArgument, bytesSent, totalMessageLength);




    DialUpComms.OutgoingPackages[messageID] = {
        id = messageID,
        partTable = {headerMessage,},
        target = target,
        channel = channel,
        prefix = prefix,
        startTime = GetTime(),
        confirmedRecievers = {},
        parts = parts,
        statusCallback = statusCallback,
    };


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
    if DialUpComms.queues then return; end;
    DialUpComms.timers = {};
    DialUpComms.queues = {};
    for i, queueName in ipairs(DialUpComms.queueTypes) do
        DialUpComms.queues[queueName] = {};
        for limitGroup in pairs(DialUpComms.commLimits) do
            DialUpComms.queues[queueName][limitGroup] = {};
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
    return not DialUpComms.ChatIsRestricted;
end;

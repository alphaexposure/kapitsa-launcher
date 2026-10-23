-- Kapitsa Launcher Tags: a DEVONthink smart rule script.
--
-- Reads the `tags:` list at the top of a Markdown file exported by Kapitsa Launcher (with
-- "Add topics as tags" ticked) and adds those tags to the record. Only records the rule hands
-- it are touched, so DEVONthink's "Convert hashtags to tags" can stay off.
--
-- Exports write tags like "Places/Funchal" and "Cost-of-living", because Obsidian nests on
-- "/" and its tags can't hold spaces. Here they become "Funchal" and "Cost of living".
--
-- Install: see the README's "DEVONthink" section.

on performSmartRule(theRecords)
	tell application id "DNtp"
		repeat with theRecord in theRecords
			set newTags to my frontMatterTags(plain text of theRecord)
			if newTags is not {} then
				set existingTags to tags of theRecord
				set addedTags to {}
				repeat with i from 1 to count of newTags
					set theTag to item i of newTags
					if existingTags does not contain theTag then set end of addedTags to theTag
				end repeat
				if addedTags is not {} then set tags of theRecord to existingTags & addedTags
			end if
		end repeat
	end tell
end performSmartRule

-- The tags in a front matter block that opens the text: "---", "tags:", "  - name" lines, "---".
on frontMatterTags(theText)
	set theLines to paragraphs of theText
	if (count of theLines) < 3 or item 1 of theLines is not "---" then return {}
	set found to {}
	set inTags to false
	repeat with i from 2 to count of theLines
		set theLine to item i of theLines
		if theLine is "---" then exit repeat
		if theLine is "tags:" then
			set inTags to true
		else if inTags and theLine starts with "  - " then
			set theTag to my readable(text 5 thru -1 of theLine)
			if theTag is not "" and found does not contain theTag then set end of found to theTag
		else
			set inTags to false
		end if
	end repeat
	return found
end frontMatterTags

-- "Places/Santa-Cruz" becomes "Santa Cruz": the part after the last "/", hyphens as spaces.
on readable(theTag)
	set savedDelimiters to AppleScript's text item delimiters
	set AppleScript's text item delimiters to "/"
	set theTag to last text item of theTag
	set AppleScript's text item delimiters to "-"
	set theWords to text items of theTag
	set AppleScript's text item delimiters to " "
	set theTag to theWords as text
	set AppleScript's text item delimiters to savedDelimiters
	return theTag
end readable

const nutritionHeading = /\b(?:nährwerte|naehrwerte|nutrition(?:al)?(?:\s+(?:values|facts))?|macros?)\b/gi;
const sectionHeading = /\b(?:zutaten|ingredients|zubereitung|preparation|instructions|method|rezept|recipe|variante?|variation|vegan)\s*(?:\d+\s*)?:|(?:^|\n)[ \t]*(?:zutaten|ingredients|zubereitung|preparation|instructions|method)[ \t]*(?=\r?\n|$)/gi;
const nutrientStart = /^(?:[-*•][ \t]+)?(?:\d+(?:[.,]\d+)?\s*(?:g\s*)?(?:kcal|calories|kalorien|protein|eiweiß|eiweiss|carbs?|kohlenhydrate|kh|fett|fat|p|c|f)\b|(?:kcal|calories|kalorien|protein|eiweiß|eiweiss|carbs?|kohlenhydrate|kh|fett|fat|p|c|f)\s*[:=]?\s*\d)/i;

/** Complete a uniquely located quote inside one bounded source nutrition section. */
export function completeNutritionEvidence(evidence: string, source: string): string {
  if (!evidence) return '';
  const start = source.indexOf(evidence);
  if (start < 0 || source.indexOf(evidence, start + evidence.length) >= 0) return '';
  const end = start + evidence.length;
  const headings = [...source.matchAll(nutritionHeading)].filter((match) => {
    const after = source.slice(match.index! + match[0].length);
    // A heading has a colon/reference or ends its line; incidental prose is not a section.
    return /^[ \t]*(?:[^:\r\n#]{0,80}:|\r?\n|$)/.test(after);
  });
  const heading = headings.findLast((match) => match.index! <= start);
  if (!heading) return evidence;
  const blockStart = heading.index!;
  const nextHeading = headings.find((match) => match.index! > blockStart)?.index ?? source.length;
  const tail = source.slice(blockStart, nextHeading);
  const headerEnd = tail.search(/[:\r\n]/) + 1;
  const section = [...tail.matchAll(sectionHeading)].find((match) => match.index! >= headerEnd)?.index ?? tail.length;
  const blank = [...tail.matchAll(/\r?\n[ \t]*\r?\n/g)].find((match) =>
    !nutrientStart.test(tail.slice(match.index! + match[0].length).trimStart()))?.index ?? tail.length;
  const hashtag = /(?:^|\s)#[\p{L}\d_]/u.exec(tail)?.index ?? tail.length;
  const blockEnd = blockStart + Math.min(section, blank, hashtag);
  // Multiple complete nutrition blocks retain the existing basis selector.
  // An earlier recipe's heading cannot establish a later ingredient's context.
  if (start >= blockEnd) return evidence;
  if (end > nextHeading && start === blockStart) {
    if (source.slice(blockEnd, nextHeading).trim()) return '';
    const remainder = completeNutritionEvidence(source.slice(nextHeading, end), source);
    if (!remainder) return '';
    const complete = (source.slice(blockStart, nextHeading) + remainder).trim();
    return complete.length <= 2000 ? complete : '';
  }
  if (end > blockEnd && !/^\s*(?:#[\p{L}\d_]+\s*)+$/u.test(source.slice(blockEnd, end))) return '';
  const complete = source.slice(blockStart, blockEnd).trim();
  // Oversized sections cannot be made trustworthy by cropping off their conflict.
  return complete.length <= 2000 ? complete : '';
}

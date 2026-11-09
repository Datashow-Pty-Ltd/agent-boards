#!/usr/bin/env node
import { formatGreeting } from "./greeting.mjs";

process.stdout.write(`${formatGreeting(process.argv[2])}\n`);
